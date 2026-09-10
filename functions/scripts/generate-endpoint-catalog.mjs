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
const expectedCodesPath = resolve(repoRoot, "functions/src/__tests__/bola/bolaExpectedCodes.generated.ts");

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
  submitBugReport: {
    trigger: "callable",
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck: "handler derives uid from request.auth.uid only",
    handlerModule: "callables/bugReporting.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["submitBugReport"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  listKnowledgeChunks: {
    trigger: "callable",
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck: "handler derives uid from request.auth.uid only",
    handlerModule: "callables/knowledgeSearch.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["listKnowledgeChunks"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  curateUsageMemoryBatch: {
    trigger: "callable",
    authMethod: "Firebase Auth with lane-scoped BurnBar Pro / Pro Max entitlement gates",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives uid from request.auth.uid only; the allowance ledger and reservation paths are built server-side from that uid and candidate payloads carry no cross-tenant object ids",
    handlerModule: "callables/usageCuration.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["curateUsageMemoryBatch"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
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
        // The cross-user proof asserts an empty resolution with the victim's
        // rows untouched; the handler does not reject, so no denial code is
        // claimed for it.
        expectedOutcome: "no-side-effect",
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
      test: "rejects cross-user App Check device operations without victim side effects",
      kind: "runtime-cross-user",
      covers: ["approveLinuxAppCheckDevice"],
      expectedOutcome: "throws",
      expectedCode: "not-found",
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
      test: "rejects cross-user App Check device operations without victim side effects",
      kind: "runtime-cross-user",
      covers: ["revokeLinuxAppCheckDevice"],
      expectedOutcome: "throws",
      expectedCode: "not-found",
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
  createTeam: {
    trigger: "callable",
    authMethod: "Firebase Auth with a server-side Data Vault entitlement check",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: [],
    ownershipCheck:
      "handler derives the founding admin from request.auth.uid only and mints a fresh server-side team id",
    handlerModule: "callables/teamRosterCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "rejects unauthenticated callable access",
        kind: "auth-only",
        covers: ["createTeam"],
        expectedOutcome: "throws",
        expectedCode: "unauthenticated",
      },
    ],
    highRiskComputerUse: false,
  },
  inviteTeamMember: {
    trigger: "callable",
    authMethod: "Firebase Auth with server-side team roster membership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid resolved against team_rosters/{teamId}/members/{uid}",
    objectIdsFromClient: ["teamId"],
    ownershipCheck: "handler requires an ACTIVE ADMIN row at team_rosters/{teamId}/members/{request.auth.uid} before resolving the invitee uid or writing an invite",
    handlerModule: "callables/teamRosterCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/teamRoster.bola.test.ts",
        test: "inviteTeamMember rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["inviteTeamMember"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  acceptTeamInvite: {
    trigger: "callable",
    authMethod: "Firebase Auth with server-side team roster membership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid resolved against team_rosters/{teamId}/members/{uid}",
    objectIdsFromClient: ["teamId"],
    ownershipCheck: "handler requires a verified email claim and an invite whose server-stored inviteeUid equals request.auth.uid; escrow key fingerprints are read from the caller's own namespace",
    handlerModule: "callables/teamRosterCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/teamRoster.bola.test.ts",
        test: "acceptTeamInvite rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["acceptTeamInvite"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  promoteTeamMember: {
    trigger: "callable",
    authMethod: "Firebase Auth with server-side team roster membership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid resolved against team_rosters/{teamId}/members/{uid}",
    objectIdsFromClient: ["teamId", "uid"],
    ownershipCheck: "handler requires an ACTIVE ADMIN row for request.auth.uid on that team, and verifies key envelope coverage addressed to the named member before activating it",
    handlerModule: "callables/teamRosterCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/teamRoster.bola.test.ts",
        test: "promoteTeamMember rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["promoteTeamMember"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  removeTeamMember: {
    trigger: "callable",
    authMethod: "Firebase Auth with server-side team roster membership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid resolved against team_rosters/{teamId}/members/{uid}",
    objectIdsFromClient: ["teamId", "targetUid"],
    ownershipCheck: "handler allows self-leave, otherwise requires an ACTIVE ADMIN row for request.auth.uid on that team",
    handlerModule: "callables/teamRosterCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/teamRoster.bola.test.ts",
        test: "removeTeamMember rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["removeTeamMember"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  abandonTeamKeyGeneration: {
    trigger: "callable",
    authMethod: "Firebase Auth with server-side team roster membership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid resolved against team_rosters/{teamId}/members/{uid}",
    objectIdsFromClient: ["teamId"],
    ownershipCheck:
      "handler requires an ACTIVE ADMIN row for request.auth.uid on that team, and burns only the next unclaimed key version, only when it is neither active nor retained and an envelope for it exists",
    handlerModule: "callables/teamRosterCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/teamRoster.bola.test.ts",
        test: "abandonTeamKeyGeneration rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["abandonTeamKeyGeneration"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  recordTeamRewrapComplete: {
    trigger: "callable",
    authMethod: "Firebase Auth with server-side team roster membership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid resolved against team_rosters/{teamId}/members/{uid}",
    objectIdsFromClient: ["teamId"],
    ownershipCheck: "handler requires an ACTIVE ADMIN row for request.auth.uid on that team and refuses any key version but the roster's current activeKeyVersion",
    handlerModule: "callables/teamRosterCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/teamRoster.bola.test.ts",
        test: "recordTeamRewrapComplete rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["recordTeamRewrapComplete"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  recordTeamSlugKeyId: {
    trigger: "callable",
    authMethod: "Firebase Auth with server-side team roster membership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid resolved against team_rosters/{teamId}/members/{uid}",
    objectIdsFromClient: ["teamId"],
    ownershipCheck:
      "handler requires an ACTIVE ADMIN row for request.auth.uid on that team and records the founding slug-key fingerprint write-once, refusing any second, different value",
    handlerModule: "teamSlugKeyRecord.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/teamRoster.bola.test.ts",
        test: "recordTeamSlugKeyId rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["recordTeamSlugKeyId"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  },
  rotateTeamKey: {
    trigger: "callable",
    authMethod: "Firebase Auth with server-side team roster membership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid resolved against team_rosters/{teamId}/members/{uid}",
    objectIdsFromClient: ["teamId"],
    ownershipCheck: "handler requires an ACTIVE ADMIN row for request.auth.uid on that team and refuses any key version but activeKeyVersion + 1",
    handlerModule: "callables/teamRosterCallables.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/teamRoster.bola.test.ts",
        test: "rotateTeamKey rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["rotateTeamKey"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
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

/**
 * Measured by the W0-12 forced-strict BOLA run. These are intentionally kept
 * separate from the contract defaults above: W1-1a drains this ledger by
 * aligning each handler's malformed, foreign, and missing-id paths.
 */
const BOLA_MEASURED_EXPECTED_CODES = {
  appendCliAgentMissionEvent: "invalid-argument",
  approveEscrowDeviceTrust: "invalid-argument",
  beginBurnbarAttachment: "invalid-argument",
  beginEncryptedSessionBlobUpload: "permission-denied",
  cancelCliAgentMission: "invalid-argument",
  claimCliAgentMission: "invalid-argument",
  claimSignalPrekeyBundle: "failed-precondition",
  commitEncryptedProjectMemorySnapshot: "permission-denied",
  commitEncryptedSearchIndexBatch: "permission-denied",
  commitKnowledgeBatch: "permission-denied",
  completeCliLink: "permission-denied",
  completeHermesPairing: "permission-denied",
  completePiAgentPairing: "permission-denied",
  composeBurnbarAttachment: "invalid-argument",
  configureKnowledgeSource: "permission-denied",
  confirmRecovery: "invalid-argument",
  connectHostedQuotaAccount: "invalid-argument",
  connectKnowledgeRepo: "permission-denied",
  connectProviderAccount: "invalid-argument",
  connectSelfHostedQuotaAccount: "invalid-argument",
  createCliAgentMission: "invalid-argument",
  createCredentialTransfer: "already-exists",
  createHermesPairing: "permission-denied",
  createPiAgentPairing: "permission-denied",
  deleteBurnbarAttachment: "invalid-argument",
  deleteHostedQuotaCredentials: "invalid-argument",
  deleteKnowledgeSource: "permission-denied",
  disconnectKnowledgeRepo: "permission-denied",
  enqueueHermesGatewayEvent: "failed-precondition",
  finalizeBurnbarAttachment: "invalid-argument",
  getEncryptedProjectMemorySnapshot: "permission-denied",
  getEncryptedSessionBlobDownloadUrl: "permission-denied",
  mintBurnbarAttachmentPartURL: "invalid-argument",
  publishAgentGrantAuthority: "permission-denied",
  publishIrohPairingPublicKey: "permission-denied",
  publishIrohPairingRecord: "permission-denied",
  publishMissionApprovalCeiling: "invalid-argument",
  publishPhoneControlAuthority: "permission-denied",
  publishRelaySenderKey: "permission-denied",
  publishSignalPrekeyBundle: "failed-precondition",
  queryConversations: "permission-denied",
  queueAgentCapabilityGrantRequest: "invalid-argument",
  recordSignalRotation: "failed-precondition",
  recordSignalSession: "failed-precondition",
  redeemMissionApprovalAnswer: "invalid-argument",
  registerEscrowDevice: "invalid-argument",
  respondMissionApproval: "invalid-argument",
  revokeHermesConnection: "permission-denied",
  revokeIrohPairingRecord: "permission-denied",
  revokePiAgentConnection: "permission-denied",
  rotateCloudVaultKey: "permission-denied",
  searchEncryptedConversationIndex: "permission-denied",
  setHermesGatewayOversightMode: "failed-precondition",
  signalPrekeyWatermark: "failed-precondition",
  submitAgentNotificationReply: "invalid-argument",
  ticketBurnbarAttachmentDownload: "invalid-argument",
  updateCliAgentMissionStatus: "invalid-argument",
  updateHermesConnectionStatus: "permission-denied",
  updatePiAgentConnectionStatus: "permission-denied",
  consumeCredentialTransfer: "permission-denied",
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

CATALOG_OVERRIDES.benchAssistant = {
  trigger: "callable",
  authMethod:
    "none — public website callable bounded by product-layer IP rate limits (bench_assistant_burst + bench_assistant_daily) enforced before any OpenRouter call",
  appCheck: "not-applicable",
  tenantSource: "none — answers only from the caller-supplied public BurnBench digest; no tenant objects are read",
  objectIdsFromClient: [],
  ownershipCheck:
    "handler reads no Firestore tenant data; it validates the payload, enforces the IP rate limits, and proxies the digest to OpenRouter",
  handlerModule: "benchAssistant.ts",
  bolaCoverage: [
    {
      file: "functions/src/__tests__/benchAssistant.test.ts",
      test: "public benchmark assistant answers only from the supplied digest and exposes no tenant objects",
      kind: "not-applicable-public",
      covers: ["benchAssistant"],
    },
  ],
  highRiskComputerUse: false,
};

CATALOG_OVERRIDES.arenaVote = {
  trigger: "callable",
  authMethod:
    "Firebase Auth required; one vote per uid per matchup via create() on {uid}__{matchupId} doc id; PRIMARY rate limits are uid-keyed (arena_vote_burst + arena_vote_daily), with a deliberately looser IP-keyed pair (arena_vote_ip_burst + arena_vote_ip_daily) as a secondary that stays inert unless the deployment sets OPENBURNBAR_TRUST_X_FORWARDED_FOR=1",
  appCheck: "not-applicable",
  tenantSource:
    "request.auth.uid — stored as voter_uid for one-vote-per-matchup dedup; no tenant objects are read",
  objectIdsFromClient: [],
  ownershipCheck:
    "handler requires Firebase Auth, validates the payload (serveId is required; a client-sent servedSwap is parsed and discarded), enforces the uid-keyed rate limits before any write, redeems the single-use arena_serves/{serveId} ticket — rejecting a ticket that names a different matchupId, was issued to a different uid, was already consumed, or has expired — and takes the served left/right orientation from that server-written ticket rather than from the request, resolves the matchup registry entry, normalizes the choice and rubric verdicts into stored left_cell/right_cell orientation, writes the vote with a deterministic {uid}__{matchupId} doc id via create() (race-proof dedup), and only then reveals competitor identities, in the orientation the voter actually saw",
  handlerModule: "arenaVote.ts",
  bolaCoverage: [
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "writes the vote and reveals identities only after the write",
      kind: "not-applicable-public",
      covers: ["arenaVote"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "rejects a vote without Firebase Auth",
      kind: "not-applicable-public",
      covers: ["arenaVote"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "rejects a duplicate vote from the same uid on the same matchup",
      kind: "not-applicable-public",
      covers: ["arenaVote"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "ignores a client-supplied servedSwap that contradicts the served orientation",
      kind: "not-applicable-public",
      covers: ["arenaVote"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "cannot be used to look up a matchup the caller was never served",
      kind: "not-applicable-public",
      covers: ["arenaVote"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "rate-limits a burst per uid even when every request comes from a new IP",
      kind: "not-applicable-public",
      covers: ["arenaVote"],
    },
  ],
  highRiskComputerUse: false,
};

CATALOG_OVERRIDES.arenaMatchup = {
  trigger: "callable",
  authMethod:
    "optional Firebase Auth; signed-in voters get previously-judged matchups excluded from the pool; rate limits (arena_matchup_burst + arena_matchup_daily) enforced before any read, keyed on the uid when signed in, else on a client IP only when OPENBURNBAR_TRUST_X_FORWARDED_FOR=1 makes one attributable, else falling back to an explicitly shared global capacity guard (arena_matchup_global_burst + arena_matchup_global_daily)",
  appCheck: "not-applicable",
  tenantSource:
    "optional request.auth.uid — used to key the rate limit, to exclude already-voted matchups via a point read on arena_votes/{uid}__{matchupId}, and to bind the issued serve ticket to that voter; no tenant objects are read",
  objectIdsFromClient: [],
  ownershipCheck:
    "handler reads arena_matchups (a collection Firestore rules deny to all clients) with a BOUNDED read — a random cursor into the id-ordered registry, a select() projection that deliberately omits left_cell/right_cell so identities are never loaded on the serving path, limit 12, plus one wrap-around page — skips matchups the caller already judged, picks the left/right orientation with a CSPRNG, records that orientation in a single-use arena_serves/{serveId} ticket bound to the matchup and (when signed in) to the uid, and returns only content-hash bundle ids, sanitized entry paths, the matchupId, and the opaque serveId — never the competitor cell identities and never the orientation itself",
  handlerModule: "arenaVote.ts",
  bolaCoverage: [
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "returns anonymized bundles and no identities without auth",
      kind: "not-applicable-public",
      covers: ["arenaMatchup"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "excludes matchups the signed-in voter already judged",
      kind: "not-applicable-public",
      covers: ["arenaMatchup"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "never loads the competitor identity columns on the serving path",
      kind: "not-applicable-public",
      covers: ["arenaMatchup"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "persists the served orientation and never discloses it to the caller",
      kind: "not-applicable-public",
      covers: ["arenaMatchup"],
    },
    {
      file: "functions/src/__tests__/arenaVote.test.ts",
      test: "reads a bounded slice of the registry rather than the whole thing",
      kind: "not-applicable-public",
      covers: ["arenaMatchup"],
    },
  ],
  highRiskComputerUse: false,
};

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

function runtimeOwned(exportedName, file, test, extra = {}) {
  return {
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    ownershipCheck: "handler derives uid from request.auth.uid and validates object path before Admin SDK access",
    bolaCoverage: [
      {
        file,
        test,
        kind: "runtime-cross-user",
        covers: [exportedName],
        expectedOutcome: "throws",
        expectedCode: extra.expectedCode ?? "not-found",
      },
    ],
    highRiskComputerUse: true,
    ...extra,
  };
}

for (const name of [
  "beginBurnbarAttachment",
  "mintBurnbarAttachmentPartURL",
  "composeBurnbarAttachment",
  "finalizeBurnbarAttachment",
  "deleteBurnbarAttachment",
  "ticketBurnbarAttachmentDownload",
]) {
  CATALOG_OVERRIDES[name] = runtimeOwned(
    name,
    "functions/src/__tests__/bola/burnbarAttachments.bola.test.ts",
    `${name} rejects cross-user object access`,
    { objectIdsFromClient: ["id"], handlerModule: "callables/burnbarAttachments.ts" },
  );
}

for (const [name, ids] of [
  ["createCliAgentMission", ["requestId", "remoteCommandID"]],
  ["cancelCliAgentMission", ["requestId"]],
  ["claimCliAgentMission", ["requestId"]],
  ["appendCliAgentMissionEvent", ["requestId", "eventId"]],
  ["updateCliAgentMissionStatus", ["requestId"]],
]) {
  CATALOG_OVERRIDES[name] = runtimeOwned(
    name,
    "functions/src/__tests__/bola/cliAgentMissions.bola.test.ts",
    `${name} rejects cross-user object access`,
    { objectIdsFromClient: ids, handlerModule: "callables/cliAgentMissions.ts" },
  );
}

CATALOG_OVERRIDES.publishMissionApprovalCeiling = runtimeOwned(
  "publishMissionApprovalCeiling",
  "functions/src/__tests__/bola/missionApprovalAnswers.bola.test.ts",
  "publishMissionApprovalCeiling rejects cross-user object access",
  { objectIdsFromClient: ["requestId"], handlerModule: "callables/missionApprovalAnswers.ts" },
);
CATALOG_OVERRIDES.redeemMissionApprovalAnswer = runtimeOwned(
  "redeemMissionApprovalAnswer",
  "functions/src/__tests__/bola/missionApprovalAnswers.bola.test.ts",
  "redeemMissionApprovalAnswer rejects cross-user object access",
  { objectIdsFromClient: ["requestId"], handlerModule: "callables/missionApprovalAnswers.ts" },
);

CATALOG_OVERRIDES.reapBurnbarAttachments = {
  trigger: "scheduled",
  authMethod: "Cloud Scheduler / platform trigger",
  appCheck: "not-applicable",
  tenantSource: "job-owned collection scans",
  objectIdsFromClient: [],
  ownershipCheck: "server-side collection filters and per-document uid fields",
  handlerModule: "scheduled/reapBurnbarAttachments.ts",
  bolaCoverage: [
    {
      file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
      test: "platform triggers are not client-callable",
      kind: "platform-trigger",
      covers: ["reapBurnbarAttachments"],
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

const merged = names
  .map((exportedName) => {
    const base = priorByName[exportedName] ?? defaultEntry(exportedName);
    const override = CATALOG_OVERRIDES[exportedName];
    return override ? { ...base, ...override, exportedName } : base;
  })
  .map((entry) => {
    const measuredCode = BOLA_MEASURED_EXPECTED_CODES[entry.exportedName];
    if (!measuredCode) return entry;

    let updatedRuntimeRef = false;
    const bolaCoverage = entry.bolaCoverage.map((ref) => {
      if (ref.kind !== "runtime-cross-user" || !ref.covers.includes(entry.exportedName)) {
        return ref;
      }
      updatedRuntimeRef = true;
      return { ...ref, expectedCode: measuredCode };
    });
    if (!updatedRuntimeRef) {
      throw new Error(`Measured BOLA code has no runtime coverage ref for ${entry.exportedName}`);
    }
    return { ...entry, bolaCoverage };
  });

// The ledger never invents a code: an object-id endpoint either has a measured
// denial code on its runtime-cross-user ref, or an explicit no-side-effect
// outcome. A throwing ref without a measured code fails generation.
const objectExpectedCodes = Object.fromEntries(
  merged
    .filter((entry) => entry.objectIdsFromClient?.length > 0)
    .map((entry) => {
      const runtimeRefs = entry.bolaCoverage.filter(
        (ref) => ref.kind === "runtime-cross-user" && ref.covers.includes(entry.exportedName),
      );
      const codedRef = runtimeRefs.find((ref) => typeof ref.expectedCode === "string");
      if (codedRef) return [entry.exportedName, codedRef.expectedCode];
      if (runtimeRefs.some((ref) => ref.expectedOutcome === "no-side-effect")) {
        return [entry.exportedName, "no-side-effect"];
      }
      throw new Error(
        `${entry.exportedName}: runtime-cross-user coverage claims a rejection but has no measured expectedCode; ` +
          "add it to BOLA_MEASURED_EXPECTED_CODES or mark the ref expectedOutcome: \"no-side-effect\"",
      );
    }),
);

// 95 pre-existing object-id endpoints + the six team roster callables that
// take a teamId / member uid from the client (D16 / P21) — the sixth,
// `abandonTeamKeyGeneration`, landed with PR 2's rotation escape hatch — plus
// the rotation completion marker (D16 / P22, PR 4) and the founding
// slug-key fingerprint recorder (D16, this PR).
if (Object.keys(objectExpectedCodes).length !== 103) {
  throw new Error(
    `Expected exactly 103 object-id endpoint codes, found ${Object.keys(objectExpectedCodes).length}`,
  );
}

const header = `/** AUTO-GENERATED by scripts/generate-endpoint-catalog.mjs — do not hand-edit rows. */
import type { EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

export const endpointAuthorizationCatalog: EndpointAuthorizationEntry[] = `;

writeFileSync(
  outPath,
  `${header}${formatTsLiteral(merged)} as EndpointAuthorizationEntry[];
`,
);

const expectedCodesHeader = `/** AUTO-GENERATED by scripts/generate-endpoint-catalog.mjs — do not hand-edit rows. */
import type { BolaLedgerCode } from "../../security/bolaCoverageTypes.js";

export const BOLA_EXPECTED_CODES: Record<string, BolaLedgerCode> = `;

writeFileSync(expectedCodesPath, `${expectedCodesHeader}${formatTsLiteral(objectExpectedCodes)};
`);

console.log(`Wrote ${merged.length} catalog entries to ${outPath}`);
console.log(`Wrote ${Object.keys(objectExpectedCodes).length} BOLA expected codes to ${expectedCodesPath}`);
