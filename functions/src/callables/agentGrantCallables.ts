/**
 * @fileoverview Agent-capability grant + mission-approval callables.
 *
 * Extracted verbatim from `computerUseSecurity.ts` (U6 split). The
 * `queueAgentCapabilityGrantRequest` handler is decomposed into cohesive helpers
 * (`parseGrantPresetSelection`, `parseGrantDeliveryTiming`,
 * `enforceLocalAuthProofGate`, `parseGrantAuthorityEnvelope`,
 * `verifyGrantAuthority`, `commitQueuedGrant`) so its cyclomatic complexity stays
 * within budget. The handler invokes them in the original order so the parse →
 * local-auth-proof → delivery/timing → trusted-device read → gate sequence (and
 * therefore every thrown HttpsError and Firestore read) is observably identical
 * to the pre-split source. The helpers are pure relocations.
 */

import { FieldValue } from "firebase-admin/firestore";
import type { DocumentReference } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { recordOrUndefined } from "../guards.js";
import { logInfo, logWarn, onCallProduction, wrapCallableHandler } from "../logging.js";
import { assertCallableApprovalNotLocked, recordCallableApprovalFailure } from "./publicRateLimit.js";
import { assertActiveBurnBarCloudProEntitlement, boundedTrimmedString } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  AGENT_GRANT_AUTHORITY_FRESHNESS_SECONDS,
  PHONE_CONTROL_ESCROW_PLATFORMS,
  boundedFirestoreDocumentId,
  boundedInteger,
  parsePhoneControlSigningKeyKind,
  requireBase64Like,
  requirePhoneControlAuthorityPublicKey,
  verifyPhoneControlAuthoritySignature,
} from "./computerUseSecurityCodecs.js";
import {
  agentGrantAuthoritySignablePayload,
  agentGrantRequestHashHex,
  cocoaReferenceSecondsNow,
  grantPresetCapabilities,
  grantPresetTrustMode,
  normalizedStringList,
  parseAgentGrantLocalAuthProof,
  queuedAgentGrantDeliveryRequiresMacApproval,
  queuedAgentGrantRequiresLocalAuthProof,
  sameStringList,
  verifyAgentGrantLocalAuthProof,
} from "./computerUseSecurityCrypto.js";
import {
  appendComputerUseAuditEvent,
  requireTrustedDeviceActionProof,
  requireTrustedEscrowDevice,
} from "./computerUseSecurityFirestore.js";
import { ALLOWED_GRANT_RUNTIMES } from "../generated/missionRuntimeCatalog.generated.js";

// Internal shapes derived from the relocated parsers/verifiers so the split adds
// no new exported type to the public surface.
type AgentGrantLocalAuthProof = NonNullable<ReturnType<typeof parseAgentGrantLocalAuthProof>>;
type PhoneControlSigningKeyKind = ReturnType<typeof parsePhoneControlSigningKeyKind>;

const ALLOWED_GRANT_CAPABILITIES = new Set([
  "desktop_browser",
  "desktop_screenshot",
  "accessibility_inspect",
  "desktop_system_input",
  "workspace_read",
  "workspace_write",
  "shell",
  "desktop_file_export",
  "shell_unrestricted",
]);

type QueuedGrantRequest = {
  requestId: string;
  runtime: string;
  threadId: string;
  preset: string;
  capabilities: string[];
  trustMode: string;
  deliveryMode: string;
  requestedAt: number;
  expiresAt: number;
  grantDurationSeconds: number;
  sourceDeviceId: string;
  clientIntentId: string;
  localAuthenticationSatisfied: boolean;
};

type GrantAuthorityEnvelope = {
  peerNodeId: string;
  counter: number;
  timestamp: number;
  intentHashBlake3: string;
  signatureEd25519: string;
};

type QueueGrantData = {
  requestId?: unknown;
  runtime?: unknown;
  threadId?: unknown;
  preset?: unknown;
  capabilities?: unknown;
  trustMode?: unknown;
  deliveryMode?: unknown;
  requestedAt?: unknown;
  expiresAt?: unknown;
  grantDurationSeconds?: unknown;
  sourceDeviceId?: unknown;
  clientIntentId?: unknown;
  localAuthenticationSatisfied?: unknown;
  localAuthProof?: unknown;
  authority?: unknown;
  nonce?: unknown;
};

type GrantPresetSelection = {
  requestId: string;
  runtime: string;
  threadId: string;
  preset: string;
  capabilities: string[];
  trustMode: string;
};

type GrantDeliveryTiming = {
  deliveryMode: string;
  requestedAt: number;
  expiresAt: number;
  grantDurationSeconds: number;
};

/**
 * Validate the preset/capability fields (`requestId`…`trustMode`) and enforce the
 * runtime allow-list + preset/trust-mode binding. This is the FIRST validation
 * stage in the original handler — it runs before the local-auth-proof parse so
 * the same throw ordering is preserved. Pure relocation.
 */
function parseGrantPresetSelection(data: QueueGrantData): GrantPresetSelection {
  const requestId = boundedTrimmedString(data.requestId, "requestId", 160, true);
  const runtime = boundedTrimmedString(data.runtime, "runtime", 80, true);
  if (!ALLOWED_GRANT_RUNTIMES.has(runtime)) throw new HttpsError("invalid-argument", "Unsupported runtime.");
  const threadId = boundedTrimmedString(data.threadId, "threadId", 240, true);
  const preset = boundedTrimmedString(data.preset, "preset", 32, true);
  const capabilities = normalizedStringList(data.capabilities, "capabilities", 16, ALLOWED_GRANT_CAPABILITIES);
  const expectedCapabilities = grantPresetCapabilities(preset);
  const trustMode = boundedTrimmedString(data.trustMode, "trustMode", 32, true);
  if (!sameStringList(capabilities, expectedCapabilities) || trustMode !== grantPresetTrustMode(preset)) {
    throw new HttpsError("permission-denied", "grant_preset_mismatch");
  }
  return { requestId, runtime, threadId, preset, capabilities, trustMode };
}

/**
 * Validate delivery mode, the mac-approval gate, the timing fields, and request
 * staleness. In the original handler this ran AFTER the local-auth-proof parse
 * and BEFORE the trusted-device read; the handler invokes it at that same point.
 * Pure relocation.
 */
function parseGrantDeliveryTiming(
  data: QueueGrantData,
  capabilities: string[],
  trustMode: string,
  nowReferenceSeconds: number,
): GrantDeliveryTiming {
  const deliveryMode = boundedTrimmedString(data.deliveryMode, "deliveryMode", 32, true);
  if (!["live", "queued", "live_then_queued"].includes(deliveryMode)) {
    throw new HttpsError("invalid-argument", "Unsupported delivery mode.");
  }
  if (queuedAgentGrantDeliveryRequiresMacApproval(capabilities, trustMode, deliveryMode)) {
    throw new HttpsError("failed-precondition", "mac_approval_required");
  }
  const requestedAt = typeof data.requestedAt === "number" ? data.requestedAt : Number(data.requestedAt);
  const expiresAt = typeof data.expiresAt === "number" ? data.expiresAt : Number(data.expiresAt);
  const grantDurationSeconds =
    typeof data.grantDurationSeconds === "number" ? data.grantDurationSeconds : Number(data.grantDurationSeconds);
  if (
    !Number.isFinite(requestedAt) ||
    !Number.isFinite(expiresAt) ||
    expiresAt <= requestedAt ||
    !Number.isFinite(grantDurationSeconds) ||
    grantDurationSeconds <= 0 ||
    grantDurationSeconds > 86400
  ) {
    throw new HttpsError("invalid-argument", "Grant request timing is invalid.");
  }
  if (nowReferenceSeconds - requestedAt > 5 * 60 || expiresAt < nowReferenceSeconds) {
    throw new HttpsError("failed-precondition", "Grant request is stale.");
  }
  return { deliveryMode, requestedAt, expiresAt, grantDurationSeconds };
}

/** Enforce the local-auth-proof presence/satisfaction gate, with audit writes. */
async function enforceLocalAuthProofGate(args: {
  uid: string;
  request: QueuedGrantRequest;
  localAuthProofRequired: boolean;
  localAuthProof: AgentGrantLocalAuthProof | undefined;
}): Promise<void> {
  const { uid, request, localAuthProofRequired, localAuthProof } = args;
  if ((localAuthProofRequired || localAuthProof) && request.localAuthenticationSatisfied !== true) {
    await appendComputerUseAuditEvent(uid, {
      eventType: "agent_grant.local_auth_proof.reject",
      reason: "local_authentication_required",
      requestId: request.requestId,
      sourceDeviceId: request.sourceDeviceId,
      preset: request.preset,
    }).catch((error) => logWarn({ event: "audit_write_failed", message: "local_auth_proof_reject", error }));
    throw new HttpsError("permission-denied", "Risky grants require fresh device authentication.");
  }
  if (localAuthProofRequired && !localAuthProof) {
    await appendComputerUseAuditEvent(uid, {
      eventType: "agent_grant.local_auth_proof.reject",
      reason: "missing_proof",
      requestId: request.requestId,
      sourceDeviceId: request.sourceDeviceId,
      preset: request.preset,
    }).catch((error) => logWarn({ event: "audit_write_failed", message: "local_auth_proof_missing", error }));
    throw new HttpsError("permission-denied", "Risky grants require a local-auth proof.");
  }
}

/** Parse + structurally validate the authority envelope and freshness. */
function parseGrantAuthorityEnvelope(rawAuthority: unknown, nowReferenceSeconds: number): GrantAuthorityEnvelope {
  const authority = recordOrUndefined(rawAuthority);
  if (!authority) {
    throw new HttpsError("invalid-argument", "authority is required.");
  }
  const peerNodeId = boundedTrimmedString(authority.peerNodeId, "authority.peerNodeId", 160, true);
  const counter = boundedInteger(authority.counter, "authority.counter", 0, Number.MAX_SAFE_INTEGER, true);
  const timestamp = typeof authority.timestamp === "number" ? authority.timestamp : Number(authority.timestamp);
  const intentHashBlake3 = boundedTrimmedString(authority.intentHashBlake3, "authority.intentHashBlake3", 64, true);
  const signatureEd25519 = requireBase64Like(authority.signatureEd25519, "authority.signatureEd25519", 32, 256);
  if (counter == null || !Number.isFinite(timestamp) || !/^[a-fA-F0-9]{64}$/u.test(intentHashBlake3)) {
    throw new HttpsError("invalid-argument", "authority is invalid.");
  }
  if (Math.abs(nowReferenceSeconds - timestamp) > AGENT_GRANT_AUTHORITY_FRESHNESS_SECONDS) {
    throw new HttpsError("failed-precondition", "Grant request authority is stale.");
  }
  return { peerNodeId, counter, timestamp, intentHashBlake3, signatureEd25519 };
}

/**
 * Read the published authority doc, verify the envelope signature, and (when a
 * local-auth proof is supplied) verify the proof. Returns the verified authority
 * public key + key kind for the transaction's re-check. Pure relocation.
 */
async function verifyGrantAuthority(args: {
  uid: string;
  authorityRef: DocumentReference;
  authority: GrantAuthorityEnvelope;
  request: QueuedGrantRequest;
  observedIntentHashHex: string;
  nowReferenceSeconds: number;
  localAuthProof: AgentGrantLocalAuthProof | undefined;
}): Promise<{ authorityPublicKey: Buffer; authorityKeyKind: PhoneControlSigningKeyKind }> {
  const { uid, authorityRef, authority, request, observedIntentHashHex, nowReferenceSeconds, localAuthProof } = args;
  const authoritySnapshot = await authorityRef.get();
  if (
    !authoritySnapshot.exists ||
    authoritySnapshot.get("peerNodeId") !== authority.peerNodeId ||
    typeof authoritySnapshot.get("publicKeyBase64") !== "string"
  ) {
    throw new HttpsError("permission-denied", "Agent grant authority is not trusted for this device.");
  }
  // F2: the published authority carries its custody class (`signingKeyKind`,
  // absent ⇒ legacy ed25519); validate the key shape and verify with the
  // matching algorithm so SE-P256 controllers work on the queued lane too.
  const authorityKeyKind = parsePhoneControlSigningKeyKind(authoritySnapshot.get("signingKeyKind") ?? undefined);
  const { bytes: authorityPublicKey } = requirePhoneControlAuthorityPublicKey(
    authoritySnapshot.get("publicKeyBase64"),
    authorityKeyKind,
  );
  const signablePayload = agentGrantAuthoritySignablePayload(
    authority.intentHashBlake3.toLowerCase(),
    authority.counter,
    authority.timestamp,
  );
  if (
    !verifyPhoneControlAuthoritySignature(
      authorityPublicKey,
      authorityKeyKind,
      signablePayload,
      authority.signatureEd25519,
    )
  ) {
    throw new HttpsError("permission-denied", "Agent grant authority signature is invalid.");
  }
  if (localAuthProof) {
    const proofStatus = verifyAgentGrantLocalAuthProof(localAuthProof, {
      sourceDeviceId: request.sourceDeviceId,
      observedIntentHashHex,
      nowReferenceSeconds,
      authorityPublicKey,
      authorityKeyKind,
    });
    if (proofStatus !== "ok") {
      await appendComputerUseAuditEvent(uid, {
        eventType: "agent_grant.local_auth_proof.reject",
        reason: proofStatus,
        proofId: localAuthProof.proofId,
        requestId: request.requestId,
        sourceDeviceId: request.sourceDeviceId,
        preset: request.preset,
      }).catch((error) => logWarn({ event: "audit_write_failed", message: "local_auth_proof_reject", error }));
      throw new HttpsError("permission-denied", `local_auth_proof_${proofStatus}`);
    }
  }
  return { authorityPublicKey, authorityKeyKind };
}

/** Atomically queue the grant request, replay-checking authority + proof. */
async function commitQueuedGrant(args: {
  uid: string;
  authorityRef: DocumentReference;
  requestRef: DocumentReference;
  authority: GrantAuthorityEnvelope;
  authorityPublicKey: Buffer;
  authorityKeyKind: PhoneControlSigningKeyKind;
  request: QueuedGrantRequest;
  localAuthProof: AgentGrantLocalAuthProof | undefined;
  payload: Record<string, unknown>;
}): Promise<void> {
  const {
    uid,
    authorityRef,
    requestRef,
    authority,
    authorityPublicKey,
    authorityKeyKind,
    request,
    localAuthProof,
    payload,
  } = args;
  await db.runTransaction(async (transaction) => {
    const proofRef = localAuthProof ? db.doc(`users/${uid}/local_auth_proofs/${localAuthProof.proofId}`) : undefined;
    const [freshAuthority, existingRequest, proofSnapshot] = await Promise.all([
      transaction.get(authorityRef),
      transaction.get(requestRef),
      proofRef ? transaction.get(proofRef) : Promise.resolve(undefined),
    ]);
    if (existingRequest.exists) {
      throw new HttpsError("already-exists", "Agent grant request is already queued.");
    }
    if (
      !freshAuthority.exists ||
      freshAuthority.get("peerNodeId") !== authority.peerNodeId ||
      freshAuthority.get("publicKeyBase64") !== authorityPublicKey.toString("base64")
    ) {
      throw new HttpsError("permission-denied", "Agent grant authority changed before the request could be queued.");
    }
    if (parsePhoneControlSigningKeyKind(freshAuthority.get("signingKeyKind") ?? undefined) !== authorityKeyKind) {
      throw new HttpsError("permission-denied", "Agent grant authority changed before the request could be queued.");
    }
    const lastQueuedCounter = freshAuthority.get("lastQueuedCounter");
    if (typeof lastQueuedCounter === "number" && authority.counter <= lastQueuedCounter) {
      throw new HttpsError("permission-denied", "Agent grant authority counter replay.");
    }
    if (proofSnapshot?.exists) {
      throw new HttpsError("permission-denied", "local_auth_proof_replay");
    }
    transaction.create(requestRef, payload);
    if (proofRef && localAuthProof) {
      transaction.create(proofRef, {
        proofId: localAuthProof.proofId,
        requestId: request.requestId,
        sourceDeviceId: request.sourceDeviceId,
        signedIntentHash: localAuthProof.signedIntentHash,
        authenticatedAt: localAuthProof.authenticatedAt,
        expiresAt: localAuthProof.expiresAt,
        consumedAt: FieldValue.serverTimestamp(),
        status: "consumed",
        schemaVersion: 1,
      });
    }
    transaction.set(
      authorityRef,
      {
        lastQueuedCounter: authority.counter,
        lastQueuedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

function buildQueuedGrantPayload(args: {
  request: QueuedGrantRequest;
  authority: GrantAuthorityEnvelope;
  authorityKeyKind: PhoneControlSigningKeyKind;
  observedIntentHashHex: string;
  localAuthProof: AgentGrantLocalAuthProof | undefined;
}): Record<string, unknown> {
  const { request, authority, authorityKeyKind, observedIntentHashHex, localAuthProof } = args;
  return {
    requestId: request.requestId,
    runtime: request.runtime,
    threadId: request.threadId,
    preset: request.preset,
    capabilities: request.capabilities,
    trustMode: request.trustMode,
    deliveryMode: request.deliveryMode,
    requestedAt: request.requestedAt,
    expiresAt: request.expiresAt,
    grantDurationSeconds: request.grantDurationSeconds,
    sourceDeviceId: request.sourceDeviceId,
    clientIntentId: request.clientIntentId,
    localAuthenticationSatisfied: request.localAuthenticationSatisfied,
    ...(localAuthProof
      ? {
          localAuthProof: {
            proofId: localAuthProof.proofId,
            deviceId: localAuthProof.deviceId,
            signedIntentHash: localAuthProof.signedIntentHash,
            authenticatedAt: localAuthProof.authenticatedAt,
            expiresAt: localAuthProof.expiresAt,
            signatureEd25519: localAuthProof.signatureEd25519,
          },
          localAuthProofVerifiedAt: FieldValue.serverTimestamp(),
        }
      : {}),
    authority: {
      peerNodeId: authority.peerNodeId,
      counter: authority.counter,
      timestamp: authority.timestamp,
      intentHashBlake3: authority.intentHashBlake3,
      signatureEd25519: authority.signatureEd25519,
      ...(authorityKeyKind === "ed25519" ? {} : { keyKind: authorityKeyKind }),
    },
    status: "queued",
    canonicalRequestHashSha256: observedIntentHashHex,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
}

export const queueAgentCapabilityGrantRequest = onCallProduction(
  "queueAgentCapabilityGrantRequest",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<QueueGrantData>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before queuing an agent grant request.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
    await assertActiveBurnBarCloudProEntitlement(uid);

    // Original validation/read order is load-bearing: a malformed field must
    // surface the SAME HttpsError it did pre-split, and an untrusted device must
    // hit `requireTrustedEscrowDevice` (permission-denied) before the
    // clientIntentId/localAuthenticationSatisfied checks — so those reads/throws
    // cannot be skipped. Each step below mirrors the original sequence exactly.
    const selection = parseGrantPresetSelection(request.data);
    const localAuthProofRequired = queuedAgentGrantRequiresLocalAuthProof(selection.capabilities, selection.trustMode);
    const localAuthProof = parseAgentGrantLocalAuthProof(request.data.localAuthProof);
    const nowReferenceSeconds = cocoaReferenceSecondsNow();
    const timing = parseGrantDeliveryTiming(
      request.data,
      selection.capabilities,
      selection.trustMode,
      nowReferenceSeconds,
    );
    const sourceDeviceId = boundedTrimmedString(request.data.sourceDeviceId, "sourceDeviceId", 160, true);
    await requireTrustedEscrowDevice(uid, sourceDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
    const clientIntentId = boundedTrimmedString(request.data.clientIntentId, "clientIntentId", 160, true);
    if (typeof request.data.localAuthenticationSatisfied !== "boolean") {
      throw new HttpsError("invalid-argument", "localAuthenticationSatisfied must be boolean.");
    }
    const grantRequest: QueuedGrantRequest = {
      requestId: selection.requestId,
      runtime: selection.runtime,
      threadId: selection.threadId,
      preset: selection.preset,
      capabilities: selection.capabilities,
      trustMode: selection.trustMode,
      deliveryMode: timing.deliveryMode,
      requestedAt: timing.requestedAt,
      expiresAt: timing.expiresAt,
      grantDurationSeconds: timing.grantDurationSeconds,
      sourceDeviceId,
      clientIntentId,
      localAuthenticationSatisfied: request.data.localAuthenticationSatisfied,
    };
    await enforceLocalAuthProofGate({ uid, request: grantRequest, localAuthProofRequired, localAuthProof });

    const authority = parseGrantAuthorityEnvelope(request.data.authority, nowReferenceSeconds);

    const observedIntentHashHex = agentGrantRequestHashHex(grantRequest);
    if (observedIntentHashHex.toLowerCase() !== authority.intentHashBlake3.toLowerCase()) {
      throw new HttpsError("permission-denied", "Agent grant authority hash does not match the request.");
    }

    const authorityRef = db.doc(`users/${uid}/agent_grant_authorities/${grantRequest.sourceDeviceId}`);
    const requestRef = db.doc(`users/${uid}/agent_capability_grant_requests/${grantRequest.requestId}`);
    const { authorityPublicKey, authorityKeyKind } = await verifyGrantAuthority({
      uid,
      authorityRef,
      authority,
      request: grantRequest,
      observedIntentHashHex,
      nowReferenceSeconds,
      localAuthProof,
    });

    const payload = buildQueuedGrantPayload({
      request: grantRequest,
      authority,
      authorityKeyKind,
      observedIntentHashHex,
      localAuthProof,
    });
    await commitQueuedGrant({
      uid,
      authorityRef,
      requestRef,
      authority,
      authorityPublicKey,
      authorityKeyKind,
      request: grantRequest,
      localAuthProof,
      payload,
    });

    if (localAuthProof) {
      await appendComputerUseAuditEvent(uid, {
        eventType: "agent_grant.local_auth_proof.consume",
        proofId: localAuthProof.proofId,
        requestId: grantRequest.requestId,
        sourceDeviceId: grantRequest.sourceDeviceId,
        signedIntentHash: localAuthProof.signedIntentHash,
        preset: grantRequest.preset,
      }).catch((error) => logWarn({ event: "audit_write_failed", message: "local_auth_proof_consume", error }));
    }

    logInfo({
      event: "callable_info",
      message: "agent_capability_grant_request_queued",
      request_id: grantRequest.requestId,
      source_device_id: grantRequest.sourceDeviceId,
      preset: grantRequest.preset,
    });
    return { ok: true, requestId: grantRequest.requestId, status: "queued" };
  },
);

/**
 * Firestore merge written by `respondMissionApproval` after the trusted-device
 * gate. Approve stays parked in `waiting_for_approval` so the Mac listener can
 * claim and continue. Deny must leave that status immediately — otherwise the
 * phone inbox keeps re-hydrating the card from the still-waiting document.
 */
export function missionApprovalResolutionWrite(args: {
  approve: boolean;
  deviceId: string;
}): Record<string, unknown> {
  const approvalStatus = args.approve ? "approved" : "rejected";
  const write: Record<string, unknown> = {
    approvalStatus,
    approvalRespondedAt: FieldValue.serverTimestamp(),
    approvedByDeviceId: args.deviceId,
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (!args.approve) {
    write.status = "canceled";
  }
  return write;
}

/**
 * Bind a CLI-agent mission approval to the responding device.
 *
 * The decision is written server-side (admin SDK bypasses Firestore rules) only
 * after confirming the responder is a TRUSTED NATIVE escrow device. This closes
 * the gap where any owner-authenticated client could flip `approvalStatus` to
 * `approved` by a bare Firestore write. Fail-closed.
 */
export const respondMissionApproval = onCallProduction(
  "respondMissionApproval",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
      request: CallableRequest<{
        requestId?: unknown;
        approve?: unknown;
        deviceId?: unknown;
        nonce?: unknown;
        actionProof?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before responding to a mission approval.");
      const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
      await assertCallableApprovalNotLocked(uid, "mission_approval_fail");
      const requestId = boundedFirestoreDocumentId(request.data.requestId, "requestId", 160);
      const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
      if (typeof request.data.approve !== "boolean") {
        throw new HttpsError("invalid-argument", "approve must be a boolean.");
      }
      const approve = request.data.approve;
      try {
        await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
        await assertActiveBurnBarCloudProEntitlement(uid);
        await requireTrustedDeviceActionProof({
          uid,
          deviceId,
          actionKind: "computer_use_mission_approval",
          subjectId: requestId,
          approve,
          nonce,
          proofRaw: request.data.actionProof,
          allowedPlatforms: PHONE_CONTROL_ESCROW_PLATFORMS,
        });
      } catch (error) {
        await recordCallableApprovalFailure(uid, "mission_approval_fail");
        throw error;
      }

      const missionRef = db.doc(`users/${uid}/cli_agent_mission_requests/${requestId}`);
      const deviceRef = db.doc(`users/${uid}/escrow_devices/${deviceId}`);

      const result = await db.runTransaction(async (transaction) => {
        const [mission, device] = await Promise.all([transaction.get(missionRef), transaction.get(deviceRef)]);
        if (!mission.exists) {
          throw new HttpsError("not-found", "Mission request was not found.");
        }
        if (mission.get("status") !== "waiting_for_approval") {
          throw new HttpsError("failed-precondition", "Mission is not waiting for approval.");
        }
        const currentApproval = mission.get("approvalStatus");
        if (currentApproval && currentApproval !== "pending") {
          throw new HttpsError("failed-precondition", "Mission approval has already been resolved.");
        }
        if (
          !device.exists ||
          device.get("trustState") !== "trusted" ||
          !PHONE_CONTROL_ESCROW_PLATFORMS.has(device.get("platform"))
        ) {
          throw new HttpsError(
            "permission-denied",
            "Mission approvals require a trusted native device. Trust this device first.",
          );
        }

        transaction.set(missionRef, missionApprovalResolutionWrite({ approve, deviceId }), { merge: true });
        return {
          approvalStatus: approve ? "approved" : "rejected",
          status: approve ? "waiting_for_approval" : "canceled",
        };
      });

      logInfo({
        event: "callable_info",
        message: "mission_approval_recorded",
        request_id: requestId,
        approved_by_device_id: deviceId,
        approval_status: result.approvalStatus,
        status: result.status,
      });
      return {
        ok: true,
        requestId,
        approvalStatus: result.approvalStatus,
        status: result.status,
        approvedByDeviceId: deviceId,
      };
    },
);
