#!/usr/bin/env node
/**
 * Regenerate endpointAuthorizationCatalog.generated.ts from functions/src/index.ts.
 *
 * The catalog is the single source of matrix rows. Hand-edit overrides in
 * CATALOG_OVERRIDES below when generator defaults are insufficient.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseGeneratedLiteral } from "./generated-literal-parser.mjs";

const repoRoot = resolve(import.meta.dirname, "../..");
const indexPath = resolve(repoRoot, "functions/src/index.ts");
const outPath = resolve(repoRoot, "functions/src/security/endpointAuthorizationCatalog.generated.ts");

function exportedNames() {
  const source = readFileSync(indexPath, "utf8");
  const names = [];
  for (const match of source.matchAll(/export\s+\{([\s\S]*?)\}\s+from\s+"[^"]+";/g)) {
    for (const part of match[1].split(",")) {
      const raw = part.trim();
      if (!raw) continue;
      names.push(
        raw
          .split(/\s+as\s+/u)
          .pop()
          ?.trim() ?? raw,
      );
    }
  }
  return [...new Set(names)].sort((a, b) => a.localeCompare(b));
}

const LOWER_TRUST_DESKTOP_POLICY_OVERRIDES = {
  beginEncryptedSessionBlobUpload: "linux-low-risk",
  bindAppCheckAttestation: "desktop-attestation-binding",
  claimSignalPrekeyBundle: "linux-low-risk",
  commitEncryptedProjectMemorySnapshot: "linux-low-risk",
  commitEncryptedSearchIndexBatch: "linux-low-risk",
  commitKnowledgeBatch: "linux-low-risk",
  getAuditLog: "linux-low-risk",
  getDataDomainUsage: "linux-low-risk",
  getEncryptedProjectMemorySnapshot: "linux-low-risk",
  getEncryptedSessionBlobDownloadUrl: "linux-low-risk",
  getHermesGatewayAttachmentDownloadUrl: "linux-low-risk",
  getProfileAvatarDownloadUrl: "linux-low-risk",
  resolveActiveIrohControllerRoutes: "linux-low-risk",
  issueHighRiskActionNonce: "desktop-nonce-bootstrap",
  listEncryptedProjectMemorySnapshots: "linux-low-risk",
  listHermesConnections: "linux-low-risk",
  listHermesGatewayClients: "linux-low-risk",
  listKnowledgeRepos: "linux-low-risk",
  listPendingCloudVaultRotationRequirements: "linux-low-risk",
  listPiAgentConnections: "linux-low-risk",
  publishSignalPrekeyBundle: "linux-low-risk",
  queryConversations: "linux-low-risk",
  recordSignalRotation: "linux-low-risk",
  recordSignalSession: "linux-low-risk",
  scanLegacyPlaintextArtifacts: "linux-low-risk",
  searchEncryptedConversationIndex: "linux-low-risk",
  searchKnowledge: "linux-low-risk",
  searchStreams: "linux-low-risk",
  signalActivationReadiness: "linux-low-risk",
  signalPrekeyWatermark: "linux-low-risk",
  uploadProviderQuotaSnapshot: "linux-low-risk",
  verifyAuditLog: "linux-low-risk",
  approveHermesGatewayDeviceGrant: "desktop-trusted-device-step-up",
  completeHermesPairing: "desktop-trusted-device-step-up",
  completePiAgentPairing: "desktop-trusted-device-step-up",
  connectHostedQuotaAccount: "desktop-trusted-device-step-up",
  connectProviderAccount: "desktop-trusted-device-step-up",
  connectProviderCredential: "desktop-trusted-device-step-up",
  connectSelfHostedQuotaAccount: "desktop-trusted-device-step-up",
  deleteHostedQuotaCredentials: "desktop-trusted-device-step-up",
  deleteProviderAccount: "desktop-trusted-device-step-up",
  deleteUserCloudData: "desktop-trusted-device-step-up",
  exportUserData: "desktop-trusted-device-step-up",
  revokeAllAccess: "desktop-trusted-device-step-up",
  revokeLinuxAttestationEnrollment: "desktop-trusted-device-step-up",
  revokeRemoteMcpClient: "desktop-trusted-device-step-up",
  updateProviderAccount: "desktop-trusted-device-step-up",
};

const LOWER_TRUST_HANDLER_MODULE_OVERRIDES = {
  bindAppCheckAttestation: "callables/escrowDeviceCallables.ts",
  issueHighRiskActionNonce: "callables/escrowDeviceCallables.ts",
  approveHermesGatewayDeviceGrant: "callables/hermesGatewayApprove.ts",
  completeHermesPairing: "callables/hermes.ts",
  completePiAgentPairing: "callables/piAgent.ts",
  connectHostedQuotaAccount: "callables/providerAccounts.ts",
  connectProviderAccount: "callables/providerAccounts.ts",
  connectProviderCredential: "callables/providerAccounts.ts",
  connectSelfHostedQuotaAccount: "callables/providerAccounts.ts",
  deleteHostedQuotaCredentials: "callables/providerAccounts.ts",
  deleteProviderAccount: "callables/providerAccounts.ts",
  deleteUserCloudData: "callables/providerAccounts.ts",
  exportUserData: "callables/dataExport.ts",
  revokeAllAccess: "callables/panic.ts",
  revokeLinuxAttestationEnrollment: "callables/linuxAttestationAdmin.ts",
  revokeRemoteMcpClient: "callables/remoteMcp.ts",
  updateProviderAccount: "callables/providerAccounts.ts",
};

/** Endpoint-specific overrides merged onto scaffold defaults during regeneration. */
const CATALOG_OVERRIDES = {
  issueIrohControllerRouteChallenge: {
    authMethod: "Firebase Auth, App Check, Cloud Pro entitlement, and a single-use high-risk nonce",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["sourceDeviceId", "connectionId", "authorityPeerNodeId", "transportNodeId"],
    ownershipCheck:
      "handler scopes every document path to request.auth.uid and transactionally joins the signed pairing, trusted host, sole trusted controller device, and key-derived controller authority before issuing a one-minute challenge",
    handlerModule: "callables/irohControllerRouteCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/irohControllerRouteCallables.test.ts",
        test: "issue challenge scopes every lookup to request.auth.uid",
        kind: "runtime-cross-user",
        covers: ["issueIrohControllerRouteChallenge"],
        expectedOutcome: "throws",
        expectedCode: "failed-precondition",
      },
    ],
    highRiskComputerUse: false,
  },
  registerIrohControllerRoute: {
    authMethod:
      "Firebase Auth, App Check, Cloud Pro entitlement, and a live single-use iroh Ed25519 possession challenge",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["challengeId"],
    ownershipCheck:
      "handler loads the challenge only below request.auth.uid, verifies its transport-key signature, then revalidates the same-user trust graph before atomically consuming it and rotating the route generation",
    handlerModule: "callables/irohControllerRouteCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/irohControllerRouteCallables.test.ts",
        test: "registration cannot consume a cross-user challenge",
        kind: "runtime-cross-user",
        covers: ["registerIrohControllerRoute"],
        expectedOutcome: "throws",
        expectedCode: "failed-precondition",
      },
    ],
    highRiskComputerUse: false,
  },
  revokeIrohControllerRoute: {
    authMethod: "Firebase Auth, App Check, a single-use high-risk nonce, and the trusted sole controller device",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["sourceDeviceId", "connectionId"],
    ownershipCheck:
      "handler derives the tenant from request.auth.uid and only advances the generation of the route bound to the pairing's sole trusted controller device",
    handlerModule: "callables/irohControllerRouteCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/irohControllerRouteCallables.test.ts",
        test: "revocation cannot mutate a cross-user route",
        kind: "runtime-cross-user",
        covers: ["revokeIrohControllerRoute"],
        expectedOutcome: "throws",
        expectedCode: "failed-precondition",
      },
    ],
    highRiskComputerUse: false,
  },
  resolveActiveIrohControllerRoutes: {
    authMethod: "Firebase Auth, App Check, and Cloud Pro entitlement; read-only fail-closed trust-graph resolution",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["connectionId"],
    ownershipCheck:
      "handler reads only request.auth.uid paths and returns one route only after revalidating pairing freshness/signature, host and controller trust, exact authority derivation, route generation, TTL, and revocation state",
    handlerModule: "callables/irohControllerRouteCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/irohControllerRouteCallables.test.ts",
        test: "resolution cannot read a cross-user route",
        kind: "runtime-cross-user",
        covers: ["resolveActiveIrohControllerRoutes"],
        expectedOutcome: "throws",
        expectedCode: "failed-precondition",
      },
    ],
    highRiskComputerUse: false,
  },
  issueLinuxAppCheckChallenge: {
    trigger: "callable",
    authMethod:
      "Firebase Auth; issues a durable UID-bound Linux attestation challenge (no App Check on the bootstrap path)",
    appCheck: "not-required",
    publicJustification:
      "Bootstrap precedes the first App Check token. Firebase Auth, UID rate limiting, production mint kill switch, server-owned bindings, and a durable five-minute challenge gate it.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives uid from request.auth.uid; challenge path and app/policy ids are server-derived while the client supplies only bounded device and release metadata",
    handlerModule: "callables/linuxAppCheck.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["issueLinuxAppCheckChallenge"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  issueLinuxAttestationEnrollmentTicket: {
    trigger: "callable",
    authMethod: "Firebase Auth; issues a UID/device/material-bound Linux registrar ticket before App Check bootstrap",
    appCheck: "not-required",
    publicJustification:
      "TPM enrollment precedes the first App Check token. Firebase Auth, exact material digests, per-user quotas, a five-minute hash-only ticket, and the production mint kill switch gate it.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives uid from request.auth.uid and binds the ticket to the AK-derived device id plus exact decoded AK, EK, and EK-certificate SHA-256 digests",
    handlerModule: "callables/linuxAppCheck.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["issueLinuxAttestationEnrollmentTicket"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  issueLinuxAttestationUploadTicket: {
    trigger: "callable",
    authMethod:
      "Firebase Auth plus possession of the durable raw Linux attestation challenge (no App Check on bootstrap)",
    appCheck: "not-required",
    publicJustification:
      "The evidence upload precedes token minting. A live single-use challenge, exact evidence digest/size binding, atomic count/byte quotas, and a hash-only ingress ticket gate it.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives uid from request.auth.uid, loads only that user's challenge path, proves possession against its stored hash, and derives app/device/release bindings from the challenge document",
    handlerModule: "callables/linuxAppCheck.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["issueLinuxAttestationUploadTicket"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  mintLinuxAppCheckToken: {
    trigger: "callable",
    authMethod:
      "Firebase Auth; lower-trust Linux attestation-gated App Check token mint (no App Check on the bootstrap path)",
    appCheck: "not-required",
    publicJustification:
      "Bootstrap mints a lower-trust Linux App Check token, so it cannot itself require one. A durable single-use challenge and pinned signed-verdict verifier gate production minting.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives uid from request.auth.uid only; the minted Linux App Check app id comes from the server config allowlist, never client-supplied tenant object ids",
    handlerModule: "callables/linuxAppCheck.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["mintLinuxAppCheckToken"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  revokeLinuxAttestationEnrollment: {
    trigger: "callable",
    authMethod: "Firebase Auth, App Check, fresh high-risk nonce, and trusted-device action proof",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["deviceId"],
    ownershipCheck:
      "handler scopes the AK-derived deviceId to request.auth.uid, validates the deterministic slot and ticket binding, and atomically preserves durable enrollment/slot tombstones with the audit-chain completion event",
    handlerModule: "callables/linuxAttestationAdmin.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/linuxAttestation.bola.test.ts",
        test: "revokeLinuxAttestationEnrollment rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["revokeLinuxAttestationEnrollment"],
        expectedOutcome: "no-side-effect",
      },
      {
        file: "functions/src/__tests__/highRiskOwnerActionCallableGuards.test.ts",
        test: "revokeLinuxAttestationEnrollment calls enforceHighRiskOwnerAction with actionKind",
        kind: "static-high-risk-wiring",
        covers: ["revokeLinuxAttestationEnrollment"],
      },
    ],
    highRiskComputerUse: true,
    actionKind: "linux_attestation_enrollment_revoke",
  },
  mintWindowsAppCheckToken: {
    trigger: "callable",
    authMethod: "Firebase Auth; attestation-gated App Check token mint (no App Check on the bootstrap path)",
    appCheck: "not-required",
    publicJustification:
      "Bootstrap that MINTS an App Check token, so it cannot itself require one (chicken-and-egg). Gated by a platform attestation verifier instead; under production config no mock verifier is registered so only AC-013's real verifier can mint.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives uid from request.auth.uid only; the minted App Check app id comes from the server config allowlist, never client-supplied tenant object ids",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["mintWindowsAppCheckToken"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  burnBarHermesGateway: {
    trigger: "http",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/hermesGateway.bola.test.ts",
        test: "burnBarHermesGateway rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["burnBarHermesGateway"],
        expectedOutcome: "throws",
        expectedCode: "not-found",
      },
    ],
  },
  latestRouterRundown: {
    trigger: "http",
    authMethod: "public read-only JSON endpoint with product-layer IP rate limit",
    appCheck: "not-applicable",
    publicJustification:
      "Public read-only router rundown JSON for the website; no tenant objects are exposed, and every request is bounded by checkPublicHttpEndpointRateLimit plus cache/maxInstances controls.",
    tenantSource: "public router_rundowns/{latest|date} document; no tenant scope",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler validates the optional date key against a plausible calendar window and reads only public router_rundowns documents",
    handlerModule: "routerRundown.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/routerRundownEndpoint.test.ts",
        test: "maps product-layer rate-limit rejection to HTTP 429 before Firestore reads",
        kind: "not-applicable-public",
        covers: ["latestRouterRundown"],
      },
    ],
    highRiskComputerUse: false,
  },
  onKnowledgeRepoPush: {
    trigger: "provider-webhook",
    authMethod: "GitHub x-hub-signature-256 HMAC over the raw request body",
    appCheck: "not-applicable",
    publicJustification:
      "Public GitHub webhook ingress is authenticated by provider HMAC before any repo mapping or writes occur.",
    tenantSource: "GitHub-signed repository full_name plus installation id mapped server-side to knowledge_repos rows",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler verifies the GitHub HMAC before reading payload fields, then maps the signed repo and installation id through server-stored match tokens",
    handlerModule: "callables/knowledgeSync.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/knowledgeRepoMatchToken.test.ts",
        test: "webhook flags only repos bound to the GitHub installation in the signed payload",
        kind: "runtime-cross-user",
        covers: ["onKnowledgeRepoPush"],
      },
    ],
    highRiskComputerUse: false,
  },
  registerDevicePushEndpoint: {
    trigger: "callable",
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["deviceId"],
    ownershipCheck:
      "handler derives uid from request.auth.uid, requires users/{uid}/escrow_devices/{deviceId} to be trusted, and writes only users/{uid}/devices/{deviceId}",
    handlerModule: "callables/devicePushRegistration.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/devicePushRegistration.bola.test.ts",
        test: "registerDevicePushEndpoint rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["registerDevicePushEndpoint"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  consumeCredentialTransfer: {
    objectIdsFromClient: ["transferId"],
    handlerModule: "callables/credentialTransfer.ts",
    ownershipCheck:
      "handler derives uid from request.auth.uid, rejects legacy code/full-token inputs before lookup, and validates ownerUid on credential_transfers/{transferId}",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/credentialTransfer.bola.test.ts",
        test: "consumeCredentialTransfer rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["consumeCredentialTransfer"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
  },
  completeCredentialTransfer: {
    objectIdsFromClient: ["transferId"],
    handlerModule: "callables/credentialTransfer.ts",
    ownershipCheck:
      "handler derives uid from request.auth.uid and requires ownerUid plus matching claim hash before consuming credential_transfers/{transferId}",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/credentialTransfer.bola.test.ts",
        test: "completeCredentialTransfer rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["completeCredentialTransfer"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
  },
  cancelCredentialTransfer: {
    objectIdsFromClient: ["transferId"],
    handlerModule: "callables/credentialTransfer.ts",
    ownershipCheck:
      "handler derives uid from request.auth.uid and requires ownerUid plus matching claim hash before releasing or cancelling credential_transfers/{transferId}",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/credentialTransfer.bola.test.ts",
        test: "cancelCredentialTransfer rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["cancelCredentialTransfer"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
  },
  createCredentialTransfer: {
    objectIdsFromClient: ["transferId"],
    handlerModule: "callables/credentialTransfer.ts",
    ownershipCheck:
      "handler derives ownerUid from request.auth.uid, rejects secret-bearing legacy fields, and creates only fresh credential_transfers/{transferId}",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/credentialTransfer.bola.test.ts",
        test: "createCredentialTransfer rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["createCredentialTransfer"],
        expectedOutcome: "throws",
      },
    ],
  },
  validateOpenTimestampsProof: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/openTimestamps.bola.test.ts",
        test: "validateOpenTimestampsProof rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["validateOpenTimestampsProof"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
  },
  completeCliLink: {
    trigger: "callable",
    authMethod: "Firebase Auth plus App Check binding and single-use high-risk nonce",
    appCheck: "required",
    tenantSource: "request.auth.uid is the sole subject of issued credentials",
    objectIdsFromClient: ["userCode"],
    ownershipCheck:
      "handler resolves a pending server-only session by normalized userCode, binds the displayed expectedPurpose, and derives the Firebase custom-token or Remote MCP subject only from request.auth.uid",
    handlerModule: "callables/cliLink.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/pairing.bola.test.ts",
        test: "completeCliLink rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["completeCliLink"],
        expectedOutcome: "throws",
        expectedCode: "not-found",
      },
    ],
    highRiskComputerUse: false,
  },
  pollCliLink: {
    trigger: "http",
    authMethod: "deviceCode plus device-secret verifier proof (no Firebase Auth)",
    appCheck: "not-applicable",
    tenantSource: "cli_link_sessions/{deviceCode} resolved server-side",
    objectIdsFromClient: ["deviceCode"],
    ownershipCheck:
      "poll and cancel require a matching device-secret verifier for the deviceCode session; approved polls return only purpose plus a client-sealed credential envelope",
    handlerModule: "callables/cliLink.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/pairing.bola.test.ts",
        test: "pollCliLink rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["pollCliLink"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
  },
  performElderWandHostedSearch: {
    objectIdsFromClient: [],
    ownershipCheck: "handler derives uid from request.auth.uid only",
    handlerModule: "elderWandHostedSearch.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["performElderWandHostedSearch"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
  },
  revokeProviderAccountDeviceLink: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/deviceLinks.bola.test.ts",
        test: "revokeProviderAccountDeviceLink rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["revokeProviderAccountDeviceLink"],
        expectedOutcome: "no-side-effect",
      },
    ],
  },
  deleteProviderCredential: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/providerAccounts.bola.test.ts",
        test: "deleteProviderCredential rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["deleteProviderCredential"],
        expectedOutcome: "no-side-effect",
      },
    ],
  },
  deleteEncryptedProjectMemorySnapshot: {
    objectIdsFromClient: ["docID"],
    ownershipCheck:
      "handler derives uid from request.auth.uid and deletes only users/{uid}/project_memory_snapshots/{docID}; tombstone is content-free",
    handlerModule: "callables/encryptedProjectMemory.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/encryptedSearch.bola.test.ts",
        test: "deleteEncryptedProjectMemorySnapshot leaves cross-user project memory untouched",
        kind: "runtime-cross-user",
        covers: ["deleteEncryptedProjectMemorySnapshot"],
        expectedOutcome: "no-side-effect",
      },
    ],
  },
  revokeRemoteMcpClient: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/remoteMcp.bola.test.ts",
        test: "revokeRemoteMcpClient rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["revokeRemoteMcpClient"],
        expectedOutcome: "no-side-effect",
      },
      {
        file: "functions/src/__tests__/highRiskOwnerActionCallableGuards.test.ts",
        test: "revokeRemoteMcpClient calls enforceHighRiskOwnerAction with actionKind",
        kind: "static-high-risk-wiring",
        covers: ["revokeRemoteMcpClient"],
      },
    ],
    highRiskComputerUse: true,
    actionKind: "remote_mcp_grant_revoke",
  },
  startCliLink: {
    trigger: "http",
    authMethod: "public rate-limited device enrollment with credential-delivery key (no tenant objects)",
    appCheck: "not-applicable",
    tenantSource: "server-generated deviceCode",
    objectIdsFromClient: [],
    ownershipCheck:
      "creates ephemeral purpose-bound cli_link_sessions with a verifier hash and credential-delivery public key; desktop_auth additionally requires an opaque 128-bit flow binding",
    handlerModule: "callables/cliLink.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "public health endpoints do not expose tenant objects",
        kind: "not-applicable-public",
        covers: ["startCliLink"],
        publicJustification: "Public CLI link bootstrap mints a fresh deviceCode; no uid-scoped object ids.",
      },
    ],
  },
  sendFcmOutbound: {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions event trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "trigger document path and server-side uid field",
    objectIdsFromClient: [],
    ownershipCheck: "trigger fires only on server-written fcm_outbound docs scoped by uid",
    handlerModule: "fcmAndroidSender.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["sendFcmOutbound"],
      },
    ],
  },
  sendVoIPOutbound: {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions event trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "trigger document path and server-side uid field",
    objectIdsFromClient: [],
    ownershipCheck: "trigger fires only on server-written voip_outbound docs scoped by uid",
    handlerModule: "apnsSender.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["sendVoIPOutbound"],
      },
    ],
  },
  rollupUserRebuild: {
    trigger: "task-queue",
    authMethod: "Cloud Tasks OIDC / platform trigger",
    appCheck: "not-applicable",
    tenantSource: "job-owned users/{uid}/rollup_jobs/current dirty marker",
    objectIdsFromClient: [],
    ownershipCheck:
      "worker accepts only scheduler-created dirty epochs and re-reads the server-side rollup job before rebuilding",
    handlerModule: "scheduled.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["rollupUserRebuild"],
      },
    ],
  },
  scanLegacyPlaintextArtifacts: {
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives uid from request.auth.uid and scans only workspaces/workspace-${uid}/teams/*/artifacts; response contains IDs and metadata flags only",
    handlerModule: "callables/sharedArtifactLegacyScan.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["scanLegacyPlaintextArtifacts"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
  },
  triggerVoIPCall: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/voipPush.bola.test.ts",
        test: "triggerVoIPCall rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["triggerVoIPCall"],
        expectedOutcome: "no-side-effect",
        expectedCode: "failed-precondition",
      },
    ],
  },
};

function defaultEntry(exportedName) {
  return {
    exportedName,
    trigger: "callable",
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["accountID"],
    ownershipCheck: "handler derives uid from request.auth.uid and validates object path before Admin SDK access",
    handlerModule: "callables/shared.ts",
    bolaCoverage: [
      {
        file: `functions/src/__tests__/bola/${exportedName}.bola.test.ts`,
        test: `${exportedName} rejects cross-user object access`,
        kind: "runtime-cross-user",
        covers: [exportedName],
        expectedOutcome: "throws",
        expectedCode: "not-found",
      },
    ],
    highRiskComputerUse: false,
  };
}

function indent(level) {
  return "  ".repeat(level);
}

function formatPropertyKey(key) {
  return /^[A-Za-z_$][\w$]*$/u.test(key) ? key : JSON.stringify(key);
}

function formatPrimitive(value) {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number" || typeof value === "boolean" || value === null) return String(value);
  throw new TypeError(`Unsupported primitive value in generated catalog: ${String(value)}`);
}

function canInlineArray(value) {
  if (!Array.isArray(value)) return false;
  return value.every((item) => item === null || ["string", "number", "boolean"].includes(typeof item));
}

function formatTsLiteral(value, level = 0) {
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]";
    if (canInlineArray(value)) {
      return `[${value.map((item) => formatPrimitive(item)).join(", ")}]`;
    }
    return `[
${value.map((item) => `${indent(level + 1)}${formatTsLiteral(item, level + 1)},`).join("\n")}
${indent(level)}]`;
  }

  if (value && typeof value === "object") {
    const entries = Object.entries(value).filter(([, item]) => item !== undefined);
    if (entries.length === 0) return "{}";
    return `{
${entries
  .map(([key, item]) => {
    const propertyKey = formatPropertyKey(key);
    const renderedValue = formatTsLiteral(item, level + 1);
    const inlineLine = `${indent(level + 1)}${propertyKey}: ${renderedValue},`;
    if (typeof item === "string" && inlineLine.length > 120) {
      return `${indent(level + 1)}${propertyKey}:\n${indent(level + 2)}${renderedValue},`;
    }
    return inlineLine;
  })
  .join("\n")}
${indent(level)}}`;
  }

  return formatPrimitive(value);
}

const names = exportedNames();
const existing = readFileSync(outPath, "utf8");
const existingJson = existing.match(
  /export const endpointAuthorizationCatalog:\s*EndpointAuthorizationEntry\[\]\s*=\s*(\[[\s\S]*\])\s*as\s*EndpointAuthorizationEntry\[\];/u,
);
if (!existingJson) {
  console.error("Could not parse existing catalog — aborting to avoid data loss.");
  process.exit(1);
}

const prior = parseGeneratedLiteral(existingJson[1]);
const priorByName = Object.fromEntries(prior.map((row) => [row.exportedName, row]));

const merged = names.map((exportedName) => {
  const base = priorByName[exportedName] ?? defaultEntry(exportedName);
  const override = CATALOG_OVERRIDES[exportedName];
  const entry = override ? { ...base, ...override, exportedName } : base;
  const lowerTrustDesktopPolicy =
    LOWER_TRUST_DESKTOP_POLICY_OVERRIDES[exportedName] ?? (entry.appCheck === "required" ? "deny" : "not-applicable");
  const handlerModule = LOWER_TRUST_HANDLER_MODULE_OVERRIDES[exportedName] ?? entry.handlerModule;
  return { ...entry, ...(handlerModule ? { handlerModule } : {}), lowerTrustDesktopPolicy };
});

const header = `/** AUTO-GENERATED by scripts/generate-endpoint-catalog.mjs — do not hand-edit rows. */
import type { EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

export const endpointAuthorizationCatalog: EndpointAuthorizationEntry[] = `;

writeFileSync(
  outPath,
  `${header}${formatTsLiteral(merged)} as EndpointAuthorizationEntry[];
`,
);

console.log(`Wrote ${merged.length} catalog entries to ${outPath}`);
