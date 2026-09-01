/**
 * @fileoverview Escrow-device trust callables — App Check attestation binding,
 * high-risk nonce issuance, escrow-device registration, and the approve
 * device-trust mutation. (`revokeEscrowDeviceTrust` lives in a sibling module and
 * is re-exported here.)
 *
 * Extracted verbatim from `computerUseSecurity.ts` (U6 split). The
 * `approveEscrowDeviceTrust` transaction body is decomposed into cohesive
 * helpers (`assertTrustChainTargetIdentity`, `resolveApprovedByDeviceId`,
 * `assertTrustChainApproverIdentity`, `assertTrustChainSignature`) so the
 * transaction closure's cyclomatic complexity stays within budget; the helpers
 * are pure relocations — identical reads, throws, and side-effects.
 */

import { FieldValue, type DocumentData, type DocumentSnapshot, type Transaction } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import {
  bindAppCheckAttestationForUid,
  enforceHighRiskComputerUseCallable,
  enforceHighRiskComputerUseCallableWithNonce,
  issueHighRiskNonceForUid,
  readAppIdFromCallableRequest,
} from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { logInfo, logWarn, wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared/validators.js";
import { fanoutDeviceApprovalRequest } from "../deviceApprovalPush.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  ESCROW_PLATFORMS,
  ESCROW_WEB_PLATFORM,
  isNativeEscrowPlatform,
  parseCloudVaultDeviceTrustChainProof,
  parseEscrowPlatform,
} from "./computerUseSecurityCodecs.js";
import {
  ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED,
  evaluateEscrowFingerprintBinding,
  verifyCloudVaultDeviceTrustChainSignature,
} from "./computerUseSecurityCrypto.js";

export { revokeEscrowDeviceTrust } from "./escrowDeviceRevoke.js";

type TrustChainProof = ReturnType<typeof parseCloudVaultDeviceTrustChainProof>;

export const bindAppCheckAttestation = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("bindAppCheckAttestation", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before binding App Check attestation.");
    enforceAuthAndAppCheck(request, uid);
    const appId = readAppIdFromCallableRequest(request);
    if (!appId) {
      throw new HttpsError("unauthenticated", "App Check attestation is required.");
    }
    const claim = await bindAppCheckAttestationForUid(uid, appId);
    logInfo({
      event: "callable_info",
      message: "app_check_attestation_bound",
      app_id: appId,
    });
    return {
      ok: true,
      appId: claim.appId,
      boundAtMillis: claim.boundAtMillis,
      maxAgeMillis: 30 * 24 * 60 * 60 * 1000,
    };
  }),
);

export const issueHighRiskActionNonce = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("issueHighRiskActionNonce", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before requesting a high-risk action nonce.");
    enforceHighRiskComputerUseCallable(request, uid, { allowLowerTrustDesktop: true });
    const { nonce, expiresAtMillis } = await issueHighRiskNonceForUid(uid);
    return { ok: true, nonce, expiresAtMillis };
  }),
);

export const registerEscrowDevice = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "registerEscrowDevice",
    async (
      request: CallableRequest<{
        deviceId?: unknown;
        deviceName?: unknown;
        platform?: unknown;
        appVersion?: unknown;
        publicKeyFingerprint?: unknown;
        keyVersion?: unknown;
        nonce?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before registering an escrow device.");
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      const deviceName = boundedTrimmedString(request.data.deviceName, "deviceName", 256, true) ?? "OpenBurnBar device";
      const platform = parseEscrowPlatform(request.data.platform);
      const appVersion = boundedTrimmedString(request.data.appVersion, "appVersion", 80, false);
      const publicKeyFingerprint = boundedTrimmedString(
        request.data.publicKeyFingerprint,
        "publicKeyFingerprint",
        256,
        false,
      );
      const keyVersion =
        typeof request.data.keyVersion === "number" && Number.isInteger(request.data.keyVersion)
          ? request.data.keyVersion
          : undefined;

      const ref = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
      const existing = await ref.get();
      if (existing.exists && existing.get("trustState") === "trusted") {
        throw new HttpsError("failed-precondition", "Escrow device is already trusted.");
      }

      const payload: Record<string, unknown> = {
        deviceId,
        deviceName,
        platform,
        trustState: "pending",
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (appVersion) payload.appVersion = appVersion;
      if (publicKeyFingerprint) payload.publicKeyFingerprint = publicKeyFingerprint;
      if (keyVersion != null) payload.keyVersion = keyVersion;
      if (!existing.exists) {
        payload.createdAt = FieldValue.serverTimestamp();
      }

      await ref.set(payload, { merge: true });
      logInfo({
        event: "callable_info",
        message: "escrow_device_registered",
        device_id: deviceId,
        platform,
      });

      // Fan out device approval push notifications to existing companion devices
      void fanoutDeviceApprovalRequest({
        uid,
        deviceId,
        deviceName,
        platform,
        safetyCode: typeof publicKeyFingerprint === "string" ? publicKeyFingerprint.slice(0, 8) : undefined,
      }).catch((err) => {
        logInfo({ event: "native_device_approval_fanout_error", error: String(err) });
      });

      return { ok: true, deviceId, trustState: "pending" };
    },
  ),
);

/**
 * Stream 6: bind approval to the device's REAL public key. Recompute the
 * fingerprint from the stored x9.63 key bytes and require it to match the device
 * doc's `publicKeyFingerprint`. When the capability flag is OFF this only logs
 * the would-be rejection; ON it fails closed. Pure relocation of the original
 * inline block.
 */
async function enforceEscrowFingerprintBinding(args: {
  transaction: Transaction;
  uid: string;
  deviceId: string;
  storedFingerprint: unknown;
  keyVersion: number;
}): Promise<void> {
  const publicKeyRef = db.doc(`users/${args.uid}/escrow_public_keys/${args.deviceId}_${args.keyVersion}`);
  const publicKeySnap = await args.transaction.get(publicKeyRef);
  const publicKeyData = publicKeySnap.exists ? publicKeySnap.get("publicKeyData") : undefined;
  const fingerprintCheck = evaluateEscrowFingerprintBinding(args.storedFingerprint, publicKeyData);
  if (!fingerprintCheck.ok) {
    logInfo({
      event: "callable_info",
      message: "escrow_device_fingerprint_binding_failed",
      device_id: args.deviceId,
      reason: fingerprintCheck.reason,
      enforced: ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED,
    });
    if (ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED) {
      throw new HttpsError(
        "failed-precondition",
        "Escrow device public-key fingerprint does not match its key. Re-register the device.",
      );
    }
  }
}

/** Resolve (and enforce) the approving device, byte-identical to the inline logic. */
async function resolveApprovedByDeviceId(args: {
  transaction: Transaction;
  uid: string;
  deviceId: string;
  approverDeviceId: string | undefined;
  platform: unknown;
  trustedNativeEmpty: boolean;
}): Promise<string> {
  const requireTrustedNativeApprover = async (): Promise<string> => {
    if (!args.approverDeviceId || args.approverDeviceId === args.deviceId) {
      throw new HttpsError("failed-precondition", "A distinct trusted native device must approve this escrow device.");
    }
    const approverRef = db.doc(`users/${args.uid}/escrow_devices/${args.approverDeviceId}`);
    const approver = await args.transaction.get(approverRef);
    const approverPlatform = approver.exists ? approver.get("platform") : undefined;
    if (!approver.exists || approver.get("trustState") !== "trusted" || !isNativeEscrowPlatform(approverPlatform)) {
      throw new HttpsError("permission-denied", "Escrow approval requires a trusted native approver.");
    }
    return args.approverDeviceId;
  };

  if (args.platform === ESCROW_WEB_PLATFORM) {
    return requireTrustedNativeApprover();
  }
  if (args.trustedNativeEmpty) {
    return args.approverDeviceId || args.deviceId;
  }
  return requireTrustedNativeApprover();
}

/** Validate that the trust-chain target identity matches the published doc. */
async function assertTrustChainTargetIdentity(args: {
  transaction: Transaction;
  uid: string;
  deviceId: string;
  keyVersion: number;
  trustChain: TrustChainProof;
}): Promise<DocumentSnapshot<DocumentData>> {
  const targetSignalIdentityKeyId = `${args.deviceId}_${args.keyVersion}`;
  if (
    args.trustChain.targetSignalIdentityKeyId !== targetSignalIdentityKeyId ||
    args.trustChain.targetSignalIdentityPublicKeyFingerprint.length === 0
  ) {
    throw new HttpsError("permission-denied", "Trust-chain target identity does not match the escrow device.");
  }
  const targetIdentityRef = db.doc(`users/${args.uid}/signal_identity_public_keys/${targetSignalIdentityKeyId}`);
  const targetIdentitySnap = await args.transaction.get(targetIdentityRef);
  if (
    !targetIdentitySnap.exists ||
    targetIdentitySnap.get("deviceId") !== args.deviceId ||
    targetIdentitySnap.get("identityKeyId") !== targetSignalIdentityKeyId ||
    targetIdentitySnap.get("keyVersion") !== args.keyVersion ||
    targetIdentitySnap.get("publicKeyFingerprint") !== args.trustChain.targetSignalIdentityPublicKeyFingerprint
  ) {
    throw new HttpsError("failed-precondition", "Trust-chain target Signal identity is not published.");
  }
  return targetIdentitySnap;
}

/** Validate the approver device + its published Signal identity for the trust chain. */
async function assertTrustChainApproverIdentity(args: {
  transaction: Transaction;
  uid: string;
  approvedByDeviceId: string;
  deviceId: string;
  snapshot: DocumentSnapshot<DocumentData>;
  isBootstrapSelfApproval: boolean;
  trustChain: TrustChainProof;
  targetSignalIdentityKeyId: string;
  targetIdentitySnap: DocumentSnapshot<DocumentData>;
}): Promise<DocumentSnapshot<DocumentData>> {
  const approverRef = db.doc(`users/${args.uid}/escrow_devices/${args.approvedByDeviceId}`);
  const approverSnap =
    args.approvedByDeviceId === args.deviceId ? args.snapshot : await args.transaction.get(approverRef);
  const approverPlatform = approverSnap.exists ? approverSnap.get("platform") : undefined;
  const approverState = approverSnap.exists ? approverSnap.get("trustState") : undefined;
  if (
    !approverSnap.exists ||
    !isNativeEscrowPlatform(approverPlatform) ||
    (!args.isBootstrapSelfApproval && approverState !== "trusted")
  ) {
    throw new HttpsError("permission-denied", "Trust-chain approver must be a trusted native device.");
  }
  const rawApproverKeyVersion = approverSnap.get("keyVersion");
  const approverKeyVersion =
    typeof rawApproverKeyVersion === "number" && Number.isInteger(rawApproverKeyVersion) ? rawApproverKeyVersion : 1;
  const approverSignalIdentityKeyId = `${args.approvedByDeviceId}_${approverKeyVersion}`;
  if (args.trustChain.approverSignalIdentityKeyId !== approverSignalIdentityKeyId) {
    throw new HttpsError("permission-denied", "Trust-chain approver identity does not match the approver device.");
  }
  const approverIdentityRef = db.doc(`users/${args.uid}/signal_identity_public_keys/${approverSignalIdentityKeyId}`);
  const approverIdentitySnap =
    approverSignalIdentityKeyId === args.targetSignalIdentityKeyId
      ? args.targetIdentitySnap
      : await args.transaction.get(approverIdentityRef);
  if (
    !approverIdentitySnap.exists ||
    approverIdentitySnap.get("deviceId") !== args.approvedByDeviceId ||
    approverIdentitySnap.get("identityKeyId") !== approverSignalIdentityKeyId ||
    approverIdentitySnap.get("keyVersion") !== approverKeyVersion ||
    approverIdentitySnap.get("publicKeyFingerprint") !== args.trustChain.approverSignalIdentityPublicKeyFingerprint
  ) {
    throw new HttpsError("failed-precondition", "Trust-chain approver Signal identity is not published.");
  }
  return approverIdentitySnap;
}

/**
 * B1 — cryptographically verify the trust-chain signature against the approver's
 * PUBLISHED Signal identity public key. Fail CLOSED. Pure relocation.
 */
function assertTrustChainSignature(args: {
  uid: string;
  deviceId: string;
  approvedByDeviceId: string;
  isBootstrapSelfApproval: boolean;
  approverIdentitySnap: DocumentSnapshot<DocumentData>;
  targetEscrowFingerprint: string;
  keyVersion: number;
  trustChain: TrustChainProof;
}): void {
  const approverPublicKeyData = args.approverIdentitySnap.get("publicKeyData");
  const trustChainSignatureVerified = verifyCloudVaultDeviceTrustChainSignature({
    approverPublicKeyDataBase64: approverPublicKeyData,
    signatureBase64: args.trustChain.signature,
    canonicalFields: {
      uid: args.uid,
      targetDeviceId: args.deviceId,
      targetEscrowPublicKeyFingerprint: args.targetEscrowFingerprint,
      targetKeyVersion: args.keyVersion,
      targetSignalIdentityKeyId: args.trustChain.targetSignalIdentityKeyId,
      targetSignalIdentityPublicKeyFingerprint: args.trustChain.targetSignalIdentityPublicKeyFingerprint,
      approverDeviceId: args.approvedByDeviceId,
      approverSignalIdentityKeyId: args.trustChain.approverSignalIdentityKeyId,
      approverSignalIdentityPublicKeyFingerprint: args.trustChain.approverSignalIdentityPublicKeyFingerprint,
    },
  });
  if (!trustChainSignatureVerified) {
    logWarn({
      event: "callable_warning",
      message: "escrow_device_trust_chain_signature_invalid",
      device_id: args.deviceId,
      approved_by_device_id: args.approvedByDeviceId,
      bootstrap: args.isBootstrapSelfApproval,
    });
    throw new HttpsError(
      "permission-denied",
      "Device trust-chain signature failed verification. The approver's signature does not match its published identity key.",
    );
  }
}

export const approveEscrowDeviceTrust = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "approveEscrowDeviceTrust",
    async (
      request: CallableRequest<{
        deviceId?: unknown;
        approverDeviceId?: unknown;
        nonce?: unknown;
        trustChain?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before approving device trust.");
      // B2 — capture whether a single-use high-risk nonce was actually consumed.
      // The bootstrap self-approval branch (a device approving ITSELF as the very
      // first trusted device) below REQUIRES one regardless of the global
      // `requireHighRiskNonce` flag, so a captured/replayed owner request cannot
      // silently enroll the first trusted device within the App Check attestation
      // window. Non-bootstrap approvals keep the existing staged-rollout behavior.
      const { nonceConsumed } = await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      const approverDeviceId = boundedTrimmedString(request.data.approverDeviceId, "approverDeviceId", 160, false);
      const trustChain = parseCloudVaultDeviceTrustChainProof(request.data.trustChain);
      const ref = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
      const result = await db.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(ref);
        if (!snapshot.exists) {
          throw new HttpsError("not-found", "Escrow device is not registered.");
        }
        const platform = snapshot.get("platform");
        const trustState = snapshot.get("trustState");
        if (trustState === "trusted") {
          const approvedByDeviceId = snapshot.get("approvedByDeviceId");
          return {
            alreadyTrusted: true,
            approvedByDeviceId: typeof approvedByDeviceId === "string" ? approvedByDeviceId : undefined,
          };
        }
        if (trustState === "revoked") {
          throw new HttpsError("failed-precondition", "Revoked escrow devices must be re-registered before approval.");
        }
        if (platform !== ESCROW_WEB_PLATFORM && !isNativeEscrowPlatform(platform)) {
          throw new HttpsError("failed-precondition", "Escrow device platform is invalid.");
        }

        const storedFingerprint = snapshot.get("publicKeyFingerprint");
        const rawKeyVersion = snapshot.get("keyVersion");
        const keyVersion = typeof rawKeyVersion === "number" && Number.isInteger(rawKeyVersion) ? rawKeyVersion : 1;
        // Stream 6: bind approval to the device's REAL public key inside the
        // transaction so a concurrent key swap can't slip past.
        await enforceEscrowFingerprintBinding({ transaction, uid, deviceId, storedFingerprint, keyVersion });

        const trustedNativeQuery = db
          .collection(`users/${uid}/escrow_devices`)
          .where("trustState", "==", "trusted")
          .where("platform", "in", Array.from(ESCROW_PLATFORMS))
          .limit(2);
        const trustedNativeDevices = await transaction.get(trustedNativeQuery);

        const approvedByDeviceId = await resolveApprovedByDeviceId({
          transaction,
          uid,
          deviceId,
          approverDeviceId,
          platform,
          trustedNativeEmpty: trustedNativeDevices.empty,
        });

        const targetEscrowFingerprint = typeof storedFingerprint === "string" ? storedFingerprint : undefined;
        if (!targetEscrowFingerprint) {
          throw new HttpsError("failed-precondition", "Escrow device is missing a key fingerprint.");
        }
        const targetIdentitySnap = await assertTrustChainTargetIdentity({
          transaction,
          uid,
          deviceId,
          keyVersion,
          trustChain,
        });

        const isBootstrapSelfApproval = trustedNativeDevices.empty && approvedByDeviceId === deviceId;

        // B2 — bootstrap self-approval (the FIRST trusted device approving itself)
        // is the single most replay-sensitive path: there is no second trusted
        // device to gate it, so a captured owner request could silently enroll a
        // trust root. Require a freshly-issued, single-use high-risk nonce here
        // REGARDLESS of the global `requireHighRiskNonce` flag. `nonceConsumed` is
        // true only when a valid nonce was actually presented and atomically
        // consumed up front; if it is false (no nonce supplied while the global
        // flag is still off), fail closed for this branch only. When App Check is
        // not enforced (local emulator) `nonceConsumed` is also false — in that
        // posture there is no attestation window to replay, so the requirement is
        // scoped to enforced deployments to avoid bricking local/test flows.
        if (isBootstrapSelfApproval && getConfig().enforceAppCheck && !nonceConsumed) {
          logWarn({
            event: "callable_warning",
            message: "escrow_device_trust_bootstrap_missing_nonce",
            device_id: deviceId,
          });
          throw new HttpsError(
            "failed-precondition",
            "Bootstrap self-approval of the first trusted device requires a fresh single-use nonce. Call issueHighRiskActionNonce and supply the nonce.",
          );
        }

        const approverIdentitySnap = await assertTrustChainApproverIdentity({
          transaction,
          uid,
          approvedByDeviceId,
          deviceId,
          snapshot,
          isBootstrapSelfApproval,
          trustChain,
          targetSignalIdentityKeyId: trustChain.targetSignalIdentityKeyId,
          targetIdentitySnap,
        });

        assertTrustChainSignature({
          uid,
          deviceId,
          approvedByDeviceId,
          isBootstrapSelfApproval,
          approverIdentitySnap,
          targetEscrowFingerprint,
          keyVersion,
          trustChain,
        });

        transaction.set(
          ref,
          {
            trustState: "trusted",
            approvedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            approvedByDeviceId,
            trustChainVersion: trustChain.version,
            trustChainAlgorithm: trustChain.algorithm,
            trustChainSignature: trustChain.signature,
            targetSignalIdentityKeyId: trustChain.targetSignalIdentityKeyId,
            targetSignalIdentityPublicKeyFingerprint: trustChain.targetSignalIdentityPublicKeyFingerprint,
            approvedBySignalIdentityKeyId: trustChain.approverSignalIdentityKeyId,
            approvedBySignalIdentityPublicKeyFingerprint: trustChain.approverSignalIdentityPublicKeyFingerprint,
            signalIdentityReapprovalRequired: false,
          },
          { merge: true },
        );
        return { alreadyTrusted: false, approvedByDeviceId };
      });

      logInfo({
        event: "callable_info",
        message: "escrow_device_trust_approved",
        device_id: deviceId,
        approved_by_device_id: result.approvedByDeviceId,
      });
      return { ok: true, deviceId, trustState: "trusted", alreadyTrusted: result.alreadyTrusted };
    },
  ),
);
