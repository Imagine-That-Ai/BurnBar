/**
 * @fileoverview CloudVault key rotation coordinator.
 *
 * The backend never receives vault keys or plaintext. Clients decrypt locally,
 * generate the next vault key locally, wrap it to surviving trusted devices, and
 * call this function with wrapper metadata. The server enforces trust,
 * monotonic generation, revoked-wrapper removal, and creates a client rewrap job.
 */

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { getConfig } from "../config.js";
import { recordOrUndefined, stripUndefinedObject } from "../guards.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { boundedTrimmedString } from "./shared.js";

const CLOUD_VAULT_WRAPPER_ALGORITHM = "ECIES-P256-AESGCM";
const CLOUD_VAULT_STATE_ALGORITHM = "AES-256-GCM";
const CLOUD_VAULT_ROTATION_SCHEMA_VERSION = 1;

type SurvivorWrapperInput = {
  wrapperId: string;
  targetDeviceId: string;
  sourceDeviceId: string;
  publicKeyFingerprint: string;
  keyVersion: number;
  wrappedVaultKey: string;
};

function boundedInteger(raw: unknown, name: string, min: number, max: number): number {
  const value = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return value;
}

function requireVaultKeyID(raw: unknown, name: string): string {
  const value = boundedTrimmedString(raw, name, 128, true);
  if (!/^v1_[a-f0-9]{32}$/.test(value)) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return value;
}

function requireSafeId(raw: unknown, name: string, maxLength = 200): string {
  const value = boundedTrimmedString(raw, name, maxLength, true);
  if (!/^[A-Za-z0-9._:-]+$/.test(value)) {
    throw new HttpsError("invalid-argument", `${name} must be path-safe.`);
  }
  return value;
}

function parseSurvivorWrappers(
  raw: unknown,
  expectedVaultKeyID: string,
  expectedGeneration: number,
): SurvivorWrapperInput[] {
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > 64) {
    throw new HttpsError("invalid-argument", "survivorWrappers must contain 1-64 wrapped keys.");
  }
  const seenTargets = new Set<string>();
  return raw.map((item, index): SurvivorWrapperInput => {
    const record = recordOrUndefined(item);
    if (!record) throw new HttpsError("invalid-argument", `survivorWrappers[${index}] is invalid.`);
    const targetDeviceId = requireSafeId(record.targetDeviceId, `survivorWrappers[${index}].targetDeviceId`, 256);
    if (seenTargets.has(targetDeviceId)) {
      throw new HttpsError("invalid-argument", `Duplicate survivor wrapper for ${targetDeviceId}.`);
    }
    seenTargets.add(targetDeviceId);
    const sourceDeviceId = requireSafeId(record.sourceDeviceId, `survivorWrappers[${index}].sourceDeviceId`, 256);
    const keyVersion = boundedInteger(record.keyVersion, `survivorWrappers[${index}].keyVersion`, 1, 1000);
    const publicKeyFingerprint = boundedTrimmedString(
      record.publicKeyFingerprint,
      `survivorWrappers[${index}].publicKeyFingerprint`,
      128,
      true,
    );
    const wrappedVaultKey = boundedTrimmedString(
      record.wrappedVaultKey,
      `survivorWrappers[${index}].wrappedVaultKey`,
      8192,
      true,
    );
    if (!/^[A-Za-z0-9+/=]+$/.test(wrappedVaultKey)) {
      throw new HttpsError("invalid-argument", `survivorWrappers[${index}].wrappedVaultKey must be base64.`);
    }
    const wrapperId =
      record.wrapperId == null
        ? `${targetDeviceId}_${keyVersion}_g${expectedGeneration}`
        : requireSafeId(record.wrapperId, `survivorWrappers[${index}].wrapperId`, 256);
    if (record.vaultKeyID != null && record.vaultKeyID !== expectedVaultKeyID) {
      throw new HttpsError("invalid-argument", `survivorWrappers[${index}].vaultKeyID mismatch.`);
    }
    return { wrapperId, targetDeviceId, sourceDeviceId, publicKeyFingerprint, keyVersion, wrappedVaultKey };
  });
}

async function requireTrustedDevice(uid: string, deviceId: string): Promise<void> {
  const snap = await db.doc(`users/${uid}/escrow_devices/${deviceId}`).get();
  if (!snap.exists || snap.get("trustState") !== "trusted") {
    throw new HttpsError("permission-denied", "CloudVault rotation requires a trusted escrow device.");
  }
}

export const rotateCloudVaultKey = onCallProduction(
  "rotateCloudVaultKey",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  async (
    request: CallableRequest<{
      callerDeviceId?: unknown;
      currentVaultKeyID?: unknown;
      newVaultKeyID?: unknown;
      expectedVaultGeneration?: unknown;
      survivorWrappers?: unknown;
      reason?: unknown;
      rotationRequirementId?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before rotating CloudVault.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
    const callerDeviceId = requireSafeId(request.data.callerDeviceId, "callerDeviceId", 256);
    await requireTrustedDevice(uid, callerDeviceId);
    const currentVaultKeyID = requireVaultKeyID(request.data.currentVaultKeyID, "currentVaultKeyID");
    const newVaultKeyID = requireVaultKeyID(request.data.newVaultKeyID, "newVaultKeyID");
    if (newVaultKeyID === currentVaultKeyID) {
      throw new HttpsError("invalid-argument", "newVaultKeyID must differ from currentVaultKeyID.");
    }
    const expectedVaultGeneration = boundedInteger(
      request.data.expectedVaultGeneration,
      "expectedVaultGeneration",
      2,
      10_000,
    );
    const survivorWrappers = parseSurvivorWrappers(
      request.data.survivorWrappers,
      newVaultKeyID,
      expectedVaultGeneration,
    );
    if (!survivorWrappers.some((wrapper) => wrapper.targetDeviceId === callerDeviceId)) {
      throw new HttpsError("failed-precondition", "The rotating device must include its own survivor wrapper.");
    }
    const reason = boundedTrimmedString(request.data.reason ?? "manual", "reason", 80, true);
    if (!["manual", "revocation_rewrap", "suspected_compromise", "device_repair", "scheduled"].includes(reason)) {
      throw new HttpsError("invalid-argument", "Unsupported CloudVault rotation reason.");
    }
    const rotationRequirementId =
      request.data.rotationRequirementId == null
        ? null
        : requireSafeId(request.data.rotationRequirementId, "rotationRequirementId", 256);

    const stateRef = db.doc(`users/${uid}/cloud_vault_state/current`);
    const jobId = `cvr_${Date.now()}_${randomBytes(8).toString("hex")}`;
    const jobRef = db.doc(`users/${uid}/cloud_vault_rotation_jobs/${jobId}`);
    const requirementRef = rotationRequirementId
      ? db.doc(`users/${uid}/cloud_vault_rotation_requirements/${rotationRequirementId}`)
      : null;
    const trustedDeviceIds = new Set<string>();
    const revokedDeviceIds = new Set<string>();

    await db.runTransaction(async (transaction) => {
      const stateSnap = await transaction.get(stateRef);
      const deviceSnaps = await Promise.all(
        survivorWrappers.map((wrapper) =>
          transaction.get(db.doc(`users/${uid}/escrow_devices/${wrapper.targetDeviceId}`)),
        ),
      );
      const requirementSnap = requirementRef ? await transaction.get(requirementRef) : null;
      const state = recordOrUndefined(stateSnap.data());
      if (!stateSnap.exists || !state || state.vaultKeyID !== currentVaultKeyID || state.status !== "active") {
        throw new HttpsError("failed-precondition", "Current CloudVault state does not match this rotation request.");
      }
      const currentGeneration = typeof state.vaultGeneration === "number" ? state.vaultGeneration : 1;
      if (expectedVaultGeneration !== currentGeneration + 1) {
        throw new HttpsError("failed-precondition", "CloudVault generation must advance by exactly one.");
      }
      for (const [index, deviceSnap] of deviceSnaps.entries()) {
        const wrapper = survivorWrappers[index];
        if (!deviceSnap.exists || deviceSnap.get("trustState") !== "trusted") {
          throw new HttpsError(
            "permission-denied",
            `Survivor wrapper target ${wrapper.targetDeviceId} is not trusted.`,
          );
        }
        trustedDeviceIds.add(wrapper.targetDeviceId);
      }
      if (requirementRef && requirementSnap) {
        const requirement = recordOrUndefined(requirementSnap.data());
        const requirementSurvivors = Array.isArray(requirement?.survivorDeviceIds)
          ? requirement.survivorDeviceIds.filter((item): item is string => typeof item === "string").sort()
          : [];
        const requestedSurvivors = survivorWrappers.map((wrapper) => wrapper.targetDeviceId).sort();
        if (
          !requirementSnap.exists ||
          !requirement ||
          requirement.status !== "pending" ||
          requirement.rotateCallable !== "rotateCloudVaultKey" ||
          requirement.currentVaultKeyID !== currentVaultKeyID ||
          requirement.currentVaultGeneration !== currentGeneration ||
          JSON.stringify(requirementSurvivors) !== JSON.stringify(requestedSurvivors)
        ) {
          throw new HttpsError(
            "failed-precondition",
            "CloudVault rotation requirement does not match this rotation request.",
          );
        }
      }

      transaction.set(
        stateRef,
        stripUndefinedObject({
          ...state,
          uid,
          vaultKeyID: newVaultKeyID,
          previousVaultKeyID: currentVaultKeyID,
          vaultGeneration: expectedVaultGeneration,
          algorithm: CLOUD_VAULT_STATE_ALGORITHM,
          status: "active",
          rotationJobId: jobId,
          rotatedByDeviceId: callerDeviceId,
          rotatedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
          schemaVersion: 2,
        }),
        { merge: false },
      );

      for (const wrapper of survivorWrappers) {
        transaction.set(
          db.doc(`users/${uid}/cloud_vault_key_wrappers/${wrapper.wrapperId}`),
          {
            uid,
            targetDeviceId: wrapper.targetDeviceId,
            sourceDeviceId: wrapper.sourceDeviceId,
            publicKeyFingerprint: wrapper.publicKeyFingerprint,
            keyVersion: wrapper.keyVersion,
            wrappedVaultKey: wrapper.wrappedVaultKey,
            vaultKeyID: newVaultKeyID,
            vaultGeneration: expectedVaultGeneration,
            rotationJobId: jobId,
            algorithm: CLOUD_VAULT_WRAPPER_ALGORITHM,
            status: "active",
            createdAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            schemaVersion: 3,
          },
          { merge: false },
        );
      }
      transaction.create(jobRef, {
        jobId,
        uid,
        status: "queued",
        reason,
        currentVaultKeyID,
        newVaultKeyID,
        fromVaultGeneration: currentGeneration,
        toVaultGeneration: expectedVaultGeneration,
        survivorDeviceIds: survivorWrappers.map((wrapper) => wrapper.targetDeviceId).sort(),
        revokedDeviceIds: [],
        totalDomains: "all",
        completedDomains: [],
        failedDomains: [],
        createdByDeviceId: callerDeviceId,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        schemaVersion: CLOUD_VAULT_ROTATION_SCHEMA_VERSION,
      });
      if (requirementRef) {
        transaction.set(
          requirementRef,
          {
            status: "queued",
            rotationJobId: jobId,
            queuedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
    });

    const wrappersSnap = await db
      .collection(`users/${uid}/cloud_vault_key_wrappers`)
      .where("vaultKeyID", "==", currentVaultKeyID)
      .get();
    const batch = db.batch();
    for (const doc of wrappersSnap.docs) {
      const wrapper = recordOrUndefined(doc.data());
      const targetDeviceId = typeof wrapper?.targetDeviceId === "string" ? wrapper.targetDeviceId : "";
      if (targetDeviceId && !trustedDeviceIds.has(targetDeviceId)) revokedDeviceIds.add(targetDeviceId);
      batch.set(
        doc.ref,
        { status: "revoked", revokedByRotationJobId: jobId, updatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
    }
    if (!wrappersSnap.empty) await batch.commit();
    if (revokedDeviceIds.size > 0) {
      await jobRef.set(
        { revokedDeviceIds: Array.from(revokedDeviceIds).sort(), updatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
    }

    logInfo({
      event: "cloud_vault.rotation_queued",
      user_id_hash: uid.slice(0, 8),
      job_id: jobId,
      from_generation: expectedVaultGeneration - 1,
      to_generation: expectedVaultGeneration,
      survivor_count: survivorWrappers.length,
    });
    return {
      ok: true,
      jobId,
      currentVaultKeyID,
      newVaultKeyID,
      vaultGeneration: expectedVaultGeneration,
      status: "queued",
    };
  },
);
