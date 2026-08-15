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

/** Endpoint-specific overrides merged onto scaffold defaults during regeneration. */
const CATALOG_OVERRIDES = {
  googlePlayDeveloperNotifications: {
    trigger: "pubsub-trigger",
    authMethod: "Google Cloud Pub/Sub topic IAM and Firebase Functions platform delivery",
    appCheck: "not-applicable",
    tenantSource:
      "server-owned Google Play token claim resolved from the RTDN purchase-token hash; the provider payload never supplies a uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "trigger accepts only Pub/Sub delivery, validates the BurnBar package, hashes the purchase token, resolves the server-owned claim, and reconciles against the Google Play Developer API before updating that claim's uid",
    handlerModule: "googlePlayRtdn.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["googlePlayDeveloperNotifications"],
      },
    ],
    highRiskComputerUse: false,
  },
  reconcileGooglePlayVoidedPurchasesDaily: {
    trigger: "scheduled",
    authMethod: "Cloud Scheduler / Firebase Functions platform trigger",
    appCheck: "not-applicable",
    tenantSource:
      "server-owned Google Play token claim resolved from the voided purchase-token hash; the provider response never supplies a uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "scheduled job lists only the configured BurnBar package, hashes each transient purchase token, resolves the server-owned claim, and routes reconciliation through the same provider-verified RTDN processor",
    handlerModule: "googlePlayVoidedPurchaseReconciler.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["reconcileGooglePlayVoidedPurchasesDaily"],
      },
    ],
    highRiskComputerUse: false,
  },
  issuePhoneControlEnrollmentGrant: {
    authMethod:
      "Firebase Auth, App Check, Cloud Pro entitlement, a single-use high-risk nonce, and the trusted host device that published the pairing",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["hostDeviceId", "connectionId", "controllerDeviceId", "controllerPeerNodeId"],
    ownershipCheck:
      "handler scopes every path to request.auth.uid, verifies the caller is the pairing's trusted publishing host and the target is a trusted mobile device, then writes a pairing-scoped short-lived single-use enrollment grant",
    handlerModule: "callables/phoneControlCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/phoneControlPairingBinding.test.ts",
        test: "a different trusted Mac cannot issue a controller grant for another host's pairing",
        kind: "runtime-cross-user",
        covers: ["issuePhoneControlEnrollmentGrant"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  issueIrohControllerRouteChallenge: {
    authMethod: "Firebase Auth, App Check, Cloud Pro entitlement, and a single-use high-risk nonce",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["sourceDeviceId", "connectionId", "authorityPeerNodeId", "transportNodeId"],
    ownershipCheck:
      "handler scopes every document path to request.auth.uid and transactionally joins the signed pairing, trusted host, matching authorized controller device, and key-derived controller authority before issuing a one-minute challenge",
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
    authMethod: "Firebase Auth, App Check, a single-use high-risk nonce, and the trusted authorized controller device",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["sourceDeviceId", "connectionId"],
    ownershipCheck:
      "handler derives the tenant from request.auth.uid and only advances the generation of the route bound to the requesting authorized controller device",
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
  meterComputerUseAction: {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions event trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "users/{uid}/computer_use_actions/{actionId} trigger path",
    objectIdsFromClient: [],
    ownershipCheck:
      "trigger derives uid from the Firestore event path and meters only the immutable source document in that user namespace",
    handlerModule: "computerUseMetering.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["meterComputerUseAction"],
      },
    ],
    highRiskComputerUse: false,
  },
  meterComputerUseSessionStart: {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions event trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "users/{uid}/computer_use_sessions/{sessionId} trigger path",
    objectIdsFromClient: [],
    ownershipCheck:
      "trigger derives uid from the Firestore event path and meters only the source session in that user namespace",
    handlerModule: "computerUseMetering.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["meterComputerUseSessionStart"],
      },
    ],
    highRiskComputerUse: false,
  },
  meterComputerUseSessionCompletion: {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions event trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "users/{uid}/computer_use_sessions/{sessionId} trigger path",
    objectIdsFromClient: [],
    ownershipCheck:
      "trigger derives uid from the Firestore event path and meters only the source session in that user namespace",
    handlerModule: "computerUseMetering.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["meterComputerUseSessionCompletion"],
      },
    ],
    highRiskComputerUse: false,
  },
  reconcileAccountErasures: {
    trigger: "scheduled",
    authMethod: "Cloud Scheduler / Firebase Functions platform trigger",
    appCheck: "not-applicable",
    tenantSource: "server-owned account_erasure_audit receipts",
    objectIdsFromClient: [],
    ownershipCheck:
      "scheduled job reads nonterminal server-owned receipts and resumes cleanup using the receipt uid; no client input is accepted",
    handlerModule: "accountDeletionReconciler.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["reconcileAccountErasures"],
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
      "Bootstrap that mints a lower-trust Linux App Check token, so it cannot itself require one. Production accepts only an account-scoped install key explicitly approved by an already trusted native device plus a durable single-use signed challenge; mock claims remain disabled.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["attestation.deviceId", "attestation.challengeId"],
    ownershipCheck:
      "handler scopes the approved key and challenge below request.auth.uid, verifies the exact configured Linux app id and Ed25519 signature, and atomically consumes the same-user challenge before minting",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/linuxAppCheckMintHandler.test.ts",
        test: "rejects cross-user challenge and device identifiers before minting",
        kind: "runtime-cross-user",
        covers: ["mintLinuxAppCheckToken"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  pushLinuxCloudReplicas: {
    authMethod: "Firebase Auth and native App Check; all replica paths are derived from request.auth.uid",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives every replica and idempotency document path from request.auth.uid and never accepts a client uid",
    handlerModule: "callables/linuxCloudReplica.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["pushLinuxCloudReplicas"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  pullLinuxCloudReplicas: {
    authMethod: "Firebase Auth and native App Check; reads are scoped to request.auth.uid",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler reads only the authenticated user's linux_cloud_replicas collection and never accepts a client uid",
    handlerModule: "callables/linuxCloudReplica.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["pullLinuxCloudReplicas"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  registerLinuxAppCheckDevice: {
    trigger: "callable",
    authMethod: "Firebase Auth plus fresh Ed25519 enrollment proof of possession",
    appCheck: "not-required",
    publicJustification:
      "Pre-App-Check bootstrap creates only a pending, non-escrow-trusted install record; a trusted native device must approve it before challenge issuance or token minting.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["deviceId"],
    ownershipCheck:
      "handler derives the tenant from request.auth.uid and binds that uid into the signed enrollment bytes; deviceId is recomputed from the submitted Ed25519 public key",
    handlerModule: "callables/linuxAppCheckDevices.ts",
    bolaCoverage: [{
      file: "functions/src/__tests__/linuxAppCheckDevices.test.ts",
      test: "registers only a fresh self-signed key-derived pending identity without granting escrow trust",
      kind: "runtime-cross-user",
      covers: ["registerLinuxAppCheckDevice"],
      expectedOutcome: "throws",
      expectedCode: "unauthenticated",
    }],
    highRiskComputerUse: false,
  },
  issueLinuxAppCheckChallenge: {
    trigger: "callable",
    authMethod: "Firebase Auth plus an approved same-account Linux install key",
    appCheck: "not-required",
    publicJustification:
      "Pre-App-Check challenge bootstrap is restricted to an already native-approved install key below the authenticated user's namespace.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["deviceId"],
    ownershipCheck:
      "handler resolves the approved install only below request.auth.uid and persists a short-lived random challenge in that same namespace",
    handlerModule: "callables/linuxAppCheckDevices.ts",
    bolaCoverage: [{
      file: "functions/src/__tests__/linuxAppCheckDevices.test.ts",
      test: "issues an opaque challenge only to approved keys and atomically consumes a valid signature once",
      kind: "runtime-cross-user",
      covers: ["issueLinuxAppCheckChallenge"],
      expectedOutcome: "throws",
      expectedCode: "permission-denied",
    }],
    highRiskComputerUse: false,
  },
  listLinuxAppCheckDevices: {
    trigger: "callable",
    authMethod: "Firebase Auth, native App Check, and a trusted phone/tablet escrow manager",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["approverDeviceId"],
    ownershipCheck:
      "handler proves the manager is a trusted native escrow device below request.auth.uid and lists only public enrollment review material from that same user namespace",
    handlerModule: "callables/linuxAppCheckDevices.ts",
    bolaCoverage: [{
      file: "functions/src/__tests__/linuxAppCheckDevices.test.ts",
      test: "lists public review material and revokes without ever returning private material",
      kind: "runtime-cross-user",
      covers: ["listLinuxAppCheckDevices"],
      expectedOutcome: "throws",
      expectedCode: "permission-denied",
    }],
    highRiskComputerUse: false,
  },
  approveLinuxAppCheckDevice: {
    trigger: "callable",
    authMethod: "Firebase Auth, native App Check, high-risk nonce, trusted native manager, and signed device action proof",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["deviceId", "approverDeviceId"],
    ownershipCheck:
      "handler scopes target and approver below request.auth.uid, verifies a nonce-bound native device action signature, and transactionally promotes only a pending key-derived identity",
    handlerModule: "callables/linuxAppCheckDevices.ts",
    bolaCoverage: [{
      file: "functions/src/__tests__/linuxAppCheckDevices.test.ts",
      test: "requires explicit trusted-native approval and an action proof",
      kind: "runtime-cross-user",
      covers: ["approveLinuxAppCheckDevice"],
      expectedOutcome: "throws",
      expectedCode: "permission-denied",
    }],
    highRiskComputerUse: true,
  },
  revokeLinuxAppCheckDevice: {
    trigger: "callable",
    authMethod: "Firebase Auth, native App Check, high-risk nonce, trusted native manager, and signed device action proof",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["deviceId", "approverDeviceId"],
    ownershipCheck:
      "handler scopes target and approver below request.auth.uid, verifies a nonce-bound native device action signature, and transactionally makes revocation irreversible",
    handlerModule: "callables/linuxAppCheckDevices.ts",
    bolaCoverage: [{
      file: "functions/src/__tests__/linuxAppCheckDevices.test.ts",
      test: "lists public review material and revokes without ever returning private material",
      kind: "runtime-cross-user",
      covers: ["revokeLinuxAppCheckDevice"],
      expectedOutcome: "throws",
      expectedCode: "permission-denied",
    }],
    highRiskComputerUse: true,
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
  issueWindowsAppCheckChallenge: {
    trigger: "callable",
    authMethod: "Firebase Auth; server-nonce bootstrap for Windows TPM attestation",
    appCheck: "not-required",
    publicJustification:
      "Bootstrap that precedes custom App Check minting, so it cannot require App Check. It returns a short-lived nonce only after Firebase Auth and exact server-configured app-id binding.",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    handlerModule: "callables/windowsAppCheck.ts",
    ownershipCheck:
      "handler derives uid from request.auth.uid and accepts only the exact server-configured, allowlisted Windows app id",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["issueWindowsAppCheckChallenge"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  issueTrustedSignalIdentityRepairChallenge: {
    objectIdsFromClient: ["deviceId"],
    ownershipCheck:
      "handler derives uid from request.auth.uid and reads only that user's trusted device and pinned escrow public key",
    handlerModule: "callables/signalIdentityRepair.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/computerUse.bola.test.ts",
        test: "issueTrustedSignalIdentityRepairChallenge rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["issueTrustedSignalIdentityRepairChallenge"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  repairTrustedSignalIdentity: {
    objectIdsFromClient: ["deviceId", "challengeId", "identityKeyId"],
    ownershipCheck:
      "handler derives uid from request.auth.uid and transactionally consumes only that user's one-time challenge, trusted device, escrow key, and Signal identity",
    handlerModule: "callables/signalIdentityRepair.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/computerUse.bola.test.ts",
        test: "repairTrustedSignalIdentity rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["repairTrustedSignalIdentity"],
        expectedOutcome: "throws",
        expectedCode: "failed-precondition",
      },
    ],
    highRiskComputerUse: false,
  },
  getWindowsRuntimeSafetyConfig: {
    trigger: "callable",
    authMethod: "Firebase Auth plus Windows TPM-backed App Check",
    appCheck: "required",
    tenantSource: "request.auth.uid; response contains global safety flags only",
    objectIdsFromClient: [],
    handlerModule: "callables/windowsRuntimeSafetyConfig.ts",
    ownershipCheck:
      "handler requires Auth and App Check, accepts no object ids, and returns only bounded global Remote Config booleans",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["getWindowsRuntimeSafetyConfig"],
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
  pollCliLink: {
    trigger: "http",
    authMethod: "deviceCode plus device-secret verifier proof (no Firebase Auth)",
    appCheck: "not-applicable",
    tenantSource: "cli_link_sessions/{deviceCode} resolved server-side",
    objectIdsFromClient: ["deviceCode"],
    ownershipCheck:
      "poll requires a matching device-secret verifier for the deviceCode session and returns only a client-sealed credential envelope",
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
  deleteDomainData: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["deleteDomainData"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
      {
        file: "functions/src/__tests__/highRiskOwnerActionCallableGuards.test.ts",
        test: "deleteDomainData calls enforceHighRiskOwnerAction with actionKind",
        kind: "static-high-risk-wiring",
        covers: ["deleteDomainData"],
      },
    ],
    highRiskComputerUse: true,
    actionKind: "data_domain_delete",
  },
  startCliLink: {
    trigger: "http",
    authMethod: "public rate-limited device enrollment with credential-delivery key (no tenant objects)",
    appCheck: "not-applicable",
    tenantSource: "server-generated deviceCode",
    objectIdsFromClient: [],
    ownershipCheck:
      "creates ephemeral cli_link_sessions with a verifier hash and credential-delivery public key; no cross-tenant reads",
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
  googlePlayDeveloperNotifications: {
    trigger: "provider-webhook",
    authMethod: "Google Play RTDN delivered over an owned Pub/Sub topic (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "purchase-token claim resolved server-side to a uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler maps the Play-signed purchase token to an existing server-owned claim before touching any uid-scoped document",
    handlerModule: "googlePlayRtdn.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["googlePlayDeveloperNotifications"],
      },
    ],
    publicJustification:
      "Provider notification endpoint authenticated by Google Play's signed RTDN payload on a project-owned Pub/Sub topic; it accepts no client-supplied object ids.",
    highRiskComputerUse: false,
  },
  onAIInboxItemNotification: {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions event trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "users/{uid}/ai_inbox_items/{itemId} trigger path",
    objectIdsFromClient: [],
    ownershipCheck:
      "trigger derives uid from the Firestore event path and fans out only to that user's device docs; the item body stays sealed and never enters the push payload",
    handlerModule: "aiInboxNotifications.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["onAIInboxItemNotification"],
      },
    ],
    highRiskComputerUse: false,
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
  submitDomainCoreShadowSamples: {
    objectIdsFromClient: ["sampleId"],
    ownershipCheck:
      "handler requires Auth, App Check, and a matching server-issued rollout-channel claim; writes immutable uid-free samples to a global TTL collection",
    handlerModule: "callables/domainCoreShadowEvidence.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/domainCoreShadowEvidence.bola.test.ts",
        test: "submitDomainCoreShadowSamples preserves victim tenant data",
        kind: "runtime-cross-user",
        covers: ["submitDomainCoreShadowSamples"],
        expectedOutcome: "no-side-effect",
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

const SIGNAL_MIGRATION_TRIGGER_NAMES = [
  "onSignalMigrationAgentIdentityWritten",
  "onSignalMigrationApprovalPolicyWritten",
  "onSignalMigrationChatThreadWritten",
  "onSignalMigrationCliSessionWritten",
  "onSignalMigrationConversationWritten",
  "onSignalMigrationMissionRequestWritten",
  "onSignalMigrationMobileAssistantChatWritten",
  "onSignalMigrationRollbackRequestWritten",
  "onSignalMigrationSubscriptionTopicWritten",
  "onSignalMigrationTextSnippetWritten",
];

for (const exportedName of SIGNAL_MIGRATION_TRIGGER_NAMES) {
  CATALOG_OVERRIDES[exportedName] = {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions Firestore trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "trigger document path and server-side uid field",
    objectIdsFromClient: [],
    ownershipCheck: "trigger reads only the user-scoped source document and writes aggregate migration telemetry",
    handlerModule: "signalMigrationTelemetry.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: [exportedName],
      },
    ],
    highRiskComputerUse: false,
  };
}

const MEMORY_PACK_AUTH_ONLY_CALLABLES = [
  ["listMemoryPacks", "callables/memoryPacks.ts"],
  ["createMemoryPackCheckoutSession", "callables/memoryPacks.ts"],
  ["redeemPlayMemoryPack", "callables/memoryPacks.ts"],
  ["settlePendingMemoryPacks", "callables/memoryPacks.ts"],
  ["redeemAppleMemoryPack", "appstore/callable.ts"],
];

for (const [exportedName, handlerModule] of MEMORY_PACK_AUTH_ONLY_CALLABLES) {
  CATALOG_OVERRIDES[exportedName] = {
    trigger: "callable",
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck: "handler derives uid from request.auth.uid only",
    handlerModule,
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: [exportedName],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  };
}

CATALOG_OVERRIDES.writeSignalAtRestDocument = {
  authMethod: "Firebase Auth with callable-level user-path and Signal-envelope validation",
  appCheck: "required",
  tenantSource: "request.auth.uid",
  objectIdsFromClient: [],
  ownershipCheck: "handler derives the user path from request.auth.uid, allows only approved collections, and atomically writes validated Signal envelopes",
  handlerModule: "callables/writeSignalAtRestDocument.ts",
  bolaCoverage: [
    {
      file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
      test: "rejects unauthenticated callable access",
      kind: "auth-only",
      covers: ["writeSignalAtRestDocument"],
      expectedOutcome: "throws",
      expectedCode: "unauthenticated",
    },
  ],
  highRiskComputerUse: false,
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
  return override ? { ...base, ...override, exportedName } : base;
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
