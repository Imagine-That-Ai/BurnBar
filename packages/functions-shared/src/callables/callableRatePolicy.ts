/**
 * @fileoverview Per-caller rate policy registry for every exported callable.
 *
 * Every `onCall` export flows through `wrapCallableHandler` / `onCallProduction`
 * (logging.ts), which resolves the callable's declared policy here at module
 * load. A callable with no registry entry fails cold start loudly — that is
 * intentional: an undeclared callable must never run unbounded.
 *
 * Policy kinds:
 *   - "limited":          the central limiter enforces the tier's per-uid
 *                         burst + sustained windows before the handler runs.
 *   - "handler-enforced": the handler already calls a bespoke volume limiter
 *                         (e.g. checkVoIPCallRateLimit); no double counting.
 *   - "exempt":           read-only, bulk-sync (bounded by a per-request cap
 *                         rather than a per-uid counter doc), per-object-bounded
 *                         (each call is capped against a server-owned object whose
 *                         creation is itself rate-limited), or admin-only.
 */

type RateWindow = { windowSeconds: number; maxAttempts: number };

export type CallableRateTier = "external-side-effect" | "destructive" | "security" | "mutation";

/**
 * Tier ceilings applied when a `limited` policy does not override `limits`.
 *   - external-side-effect: outbound artifacts / pushes / mission dispatch.
 *   - destructive:          account- or domain-wide delete/purge.
 *   - security:             credential, token, key, device-trust, pairing,
 *                           grant, recovery, and nonce mutations.
 *   - mutation:             any other owner-scoped write.
 */
export const CALLABLE_RATE_TIERS: Record<CallableRateTier, { burst: RateWindow; sustained: RateWindow }> = {
  "external-side-effect": { burst: { windowSeconds: 60, maxAttempts: 5 }, sustained: { windowSeconds: 86_400, maxAttempts: 50 } },
  destructive: { burst: { windowSeconds: 60, maxAttempts: 3 }, sustained: { windowSeconds: 86_400, maxAttempts: 20 } },
  security: { burst: { windowSeconds: 60, maxAttempts: 10 }, sustained: { windowSeconds: 86_400, maxAttempts: 200 } },
  mutation: { burst: { windowSeconds: 60, maxAttempts: 60 }, sustained: { windowSeconds: 86_400, maxAttempts: 2_000 } },
};

export type CallableRatePolicy =
  | {
      kind: "limited";
      tier: CallableRateTier;
      limits?: { burst: RateWindow; sustained: RateWindow };
      reason: string;
    }
  | { kind: "handler-enforced"; checker: string; module: string }
  | { kind: "exempt"; category: "read-only" | "bulk-sync" | "per-object-bounded" | "admin-only"; reason: string };

function limited(tier: CallableRateTier, reason: string): CallableRatePolicy {
  return { kind: "limited", tier, reason };
}

function enforced(checker: string, module: string): CallableRatePolicy {
  return { kind: "handler-enforced", checker, module };
}

function readOnly(reason: string): CallableRatePolicy {
  return { kind: "exempt", category: "read-only", reason };
}

function bulkSync(reason: string): CallableRatePolicy {
  return { kind: "exempt", category: "bulk-sync", reason };
}

function perObjectBounded(reason: string): CallableRatePolicy {
  return { kind: "exempt", category: "per-object-bounded", reason };
}

/**
 * One entry per callable `exportedName` in
 * functions/src/security/endpointAuthorizationCatalog.generated.ts. The
 * inventory test (callableRatePolicyInventory.test.ts) asserts this map stays
 * in lockstep with the catalog in both directions.
 */
export const CALLABLE_RATE_POLICIES = {
  abandonTeamKeyGeneration: enforced("checkTeamRosterMutationRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  acceptTeamInvite: enforced("checkTeamInviteAcceptRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  adoptProviderAccountForDevice: limited(
    "security",
    "Links a provider credential to a device under the caller; device-link mutations need a bounded retry surface.",
  ),
  appendCliAgentMissionEvent: perObjectBounded(
    "Host streams one event per ~2 s plus one per transcript piece; capped per mission at MAX_MISSION_EVENT_SEQUENCE=20,000 behind the claim-minted hostWriteNonce, and missions are create-limited by checkMissionCreateRateLimit.",
  ),
  approveEscrowDeviceTrust: limited(
    "security",
    "Device-trust approval mutates the escrow trust graph; only failure lockouts existed before this tier.",
  ),
  approveHermesGatewayDeviceGrant: limited(
    "security",
    "Approves a gateway device grant; failure lockouts bound retries but not granted-call volume.",
  ),
  approveLinuxAppCheckDevice: limited(
    "security",
    "Promotes a pending Linux device key to trusted inside a nonce-bound transaction.",
  ),
  arenaMatchup: enforced("checkArenaMatchupRateLimit", "functions-sync/src/domains/telemetry/arenaVote.ts"),
  arenaVote: enforced("checkArenaVoteRateLimit", "functions-sync/src/domains/telemetry/arenaVote.ts"),
  backfillPrivacyPlaintext: limited(
    "destructive",
    "Account-wide sweep that reseals/deletes plaintext fields across every user collection.",
  ),
  backfillProviderAccountDeviceLinks: limited(
    "security",
    "Account-wide sweep writing provider-account device links; device-link mutations stay in the security tier.",
  ),
  beginBurnbarAttachment: limited(
    "mutation",
    "Creates an attachment reservation row; byteCount is bounded by FILE_CAP_BYTES but calls themselves are not.",
  ),
  beginEncryptedSessionBlobUpload: bulkSync(
    "Session-log upload path mints one bounded write URL per call capped by getConfig().encryptedSessionBlobMaxBytes; a per-uid counter doc would add write amplification on every sync flush.",
  ),
  beginEntitlementBinding: limited(
    "mutation",
    "Starts an App Store entitlement binding and writes the caller's binding record.",
  ),
  beginPasskeyAssertion: limited(
    "security",
    "Mints a WebAuthn assertion challenge doc; challenge issuance is a credential ceremony.",
  ),
  benchAssistant: enforced("checkBenchAssistantRateLimit", "functions-sync/src/domains/telemetry/benchAssistant.ts"),
  bindAppCheckAttestation: limited(
    "security",
    "Binds an App Check app id to the account's attestation claim surface.",
  ),
  cancelCliAgentMission: limited(
    "mutation",
    "Proof-gated single mission status transition to cancelled; owner-scoped write.",
  ),
  cancelCredentialTransfer: limited(
    "security",
    "Releases or cancels a credential_transfers record — a credential custody mutation.",
  ),
  claimCliAgentMission: perObjectBounded(
    "Single-use per mission (pending + unclaimed precondition in a transaction); a 100-agent fan-out legitimately claims 100 missions at once, and mission creation is limited by checkMissionCreateRateLimit.",
  ),
  claimSignalPrekeyBundle: limited(
    "security",
    "Consumes one-time Signal prekeys from the caller's directory; prekey mutations are credential material.",
  ),
  commitEncryptedProjectMemorySnapshot: bulkSync(
    "Snapshot sync writes one bounded doc per call (sealedBoxBase64 <= 1,500,000 chars via requireCloudVaultBlobEnvelope) plus an optional legacy tombstone; a counter doc on this path adds a write per sync flush.",
  ),
  commitEncryptedSearchIndexBatch: bulkSync(
    "Index sync batches are capped at 50 documents + 800 chunks per call (requireRecordArray) and the assertCloudSearchIndexWriteBudget write budget; a counter doc would double-write every sync commit.",
  ),
  commitKnowledgeBatch: bulkSync(
    "Knowledge sync commits up to MAX_BATCH_VECTORS=800 vectors per call with MAX_CHUNK_BYTES=64KiB per chunk; a counter doc would add a write to every high-frequency sync batch.",
  ),
  completeCliLink: limited(
    "security",
    "Completes a device-pairing link; the failure lockout bounds bad codes, not successful pairing volume.",
  ),
  completeHermesPairing: enforced("checkHermesRateLimit", "functions-media/src/domains/hermes/hermes.ts"),
  completePiAgentPairing: enforced("checkPiAgentRateLimit", "functions-identity/src/domains/identity/piAgent.ts"),
  completeCredentialTransfer: limited(
    "security",
    "Completes a credential transfer against ownerUid + claim hash; credential custody mutation.",
  ),
  connectHostedQuotaAccount: limited(
    "security",
    "Connects a hosted-quota credential to the account; provider-credential connect mutations are security tier.",
  ),
  connectKnowledgeRepo: limited(
    "mutation",
    "Writes a knowledge_repos doc after validating the GitHub installation via providerFetch; owner-scoped connect.",
  ),
  connectProviderAccount: limited(
    "security",
    "Stores a provider credential under the account via the high-risk owner-action ceremony.",
  ),
  connectProviderCredential: limited(
    "security",
    "Legacy provider-credential connect path; same security-tier treatment as connectProviderAccount.",
  ),
  connectSelfHostedQuotaAccount: limited(
    "security",
    "Registers a self-hosted quota credential/endpoint under the caller's account.",
  ),
  consumeCredentialTransfer: limited(
    "security",
    "Consumes a credential_transfers record by claim hash; credential custody mutation.",
  ),
  createCliAgentMission: enforced("checkMissionCreateRateLimit", "functions-sync/src/domains/missions/cliAgentMissions.ts"),
  createCliAgentMissionGroup: enforced("checkMissionCreateRateLimit", "functions-sync/src/domains/missions/cliAgentMissions.ts"),
  createCredentialTransfer: limited(
    "security",
    "Creates a credential_transfers record for cross-device credential custody.",
  ),
  createHermesPairing: enforced("checkHermesRateLimit", "functions-media/src/domains/hermes/hermes.ts"),
  createPiAgentPairing: enforced("checkPiAgentRateLimit", "functions-identity/src/domains/identity/piAgent.ts"),
  createStripeBurnBarProCheckoutSession: limited(
    "external-side-effect",
    "Each call creates a Stripe checkout session — a third-party artifact per invocation.",
  ),
  createStripeBurnBarProPortalSession: limited(
    "external-side-effect",
    "Each call creates a Stripe billing-portal session — a third-party artifact per invocation.",
  ),
  createTeam: enforced("checkTeamRosterMutationRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  composeBurnbarAttachment: limited(
    "mutation",
    "Marks one attachment composing and fans out part composition; owner-scoped write.",
  ),
  configureKnowledgeSource: limited(
    "mutation",
    "Writes the caller's knowledge source manifest; owner-scoped write.",
  ),
  curateUsageMemoryBatch: limited(
    "mutation",
    "Owner-funded curation batch capped at MAX_BATCH_CANDIDATES=25 and already bounded by the reserveUsageCurationTokens allowance ledger.",
  ),
  deleteBurnbarAttachment: limited(
    "mutation",
    "Single-object delete of one attachment plus its storage object.",
  ),
  deleteDomainData: limited(
    "destructive",
    "Purges an entire data domain for the account — a domain-wide delete.",
  ),
  deleteEncryptedProjectMemorySnapshot: limited(
    "mutation",
    "Deletes one project_memory_snapshots doc and writes a content-free tombstone.",
  ),
  deleteHostedQuotaCredentials: limited(
    "security",
    "Deletes hosted-quota credentials; credential deletes sit in the security tier, not destructive.",
  ),
  deleteKnowledgeSource: limited(
    "mutation",
    "Deletes a single knowledge source manifest for the caller.",
  ),
  deleteProviderAccount: limited(
    "security",
    "Deletes a provider account and its credential material under the caller.",
  ),
  deleteProviderCredential: limited(
    "security",
    "Deletes a provider credential and rewires the account record; credential mutation.",
  ),
  deleteUserCloudData: limited(
    "destructive",
    "Deletes all cloud data for the account — the account-wide erasure path.",
  ),
  disconnectKnowledgeRepo: limited(
    "mutation",
    "Deletes one knowledge_repos doc for the caller.",
  ),
  enqueueHermesGatewayEvent: enforced("checkHermesGatewayBearerRateLimit", "functions-media/src/callables/hermesGatewayEnqueue.ts"),
  exportUserData: limited(
    "mutation",
    "High-risk data export; the required appendAuditEventRequired audit write makes this a mutation, not read-only.",
  ),
  finalizeBurnbarAttachment: limited(
    "mutation",
    "Finalizes an attachment and meters the outbound/inbound quota docs.",
  ),
  getAuditLog: readOnly("Reads the caller's audit log chain; no writes."),
  getDataDomainUsage: readOnly("Aggregates the caller's usage counters; no writes."),
  getEncryptedProjectMemorySnapshot: readOnly("Reads one project_memory_snapshots doc; no writes."),
  getEncryptedSessionBlobDownloadUrl: readOnly(
    "Mints a download URL for the caller's own session blob; no writes besides logging.",
  ),
  getHermesGatewayAttachmentDownloadUrl: readOnly(
    "Mints a download URL for the caller's own gateway attachment; no writes.",
  ),
  getProfileAvatarDownloadUrl: readOnly("Mints a download URL for the caller's own avatar object; no writes."),
  getWindowsRuntimeSafetyConfig: readOnly("Returns bounded Remote Config booleans; no writes."),
  grantMediaGrandfather: { kind: "exempt", category: "admin-only", reason: "Requires the mediaSkuAdmin custom claim before it writes any entitlement." },
  insightsHostedAnswer: enforced("checkHostedInsightsAnswerRateLimit", "functions-sync/src/domains/search/insightsHostedAnswer.ts"),
  inviteTeamMember: enforced("checkTeamInviteRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  issueHighRiskActionNonce: {
    kind: "limited",
    tier: "security",
    limits: { burst: { windowSeconds: 60, maxAttempts: 120 }, sustained: { windowSeconds: 86_400, maxAttempts: 20_000 } },
    reason:
      "Nonce mint is the faucet for every proof-gated callable (mission event streams mint one per event); limits are looser than the security tier so legitimate streams are not starved, but unbounded minting of nonce docs is still capped.",
  },
  issueIrohControllerRouteChallenge: limited(
    "security",
    "Issues a one-minute pairing route challenge after revalidating the trust graph.",
  ),
  issueLinuxAppCheckChallenge: enforced("checkPublicHttpEndpointRateLimit", "functions-identity/src/domains/app-check/linuxAppCheckDevices.ts"),
  issuePhoneControlEnrollmentGrant: limited(
    "security",
    "Writes a pairing-scoped single-use enrollment grant for a trusted device.",
  ),
  issueRemoteMcpGrant: limited(
    "security",
    "Issues a remote-MCP access grant; grant issuance is a security mutation.",
  ),
  issueTrustedSignalIdentityRepairChallenge: limited(
    "security",
    "Creates a one-time Signal identity repair challenge for a trusted device.",
  ),
  issueWindowsAppCheckChallenge: enforced("checkPublicHttpEndpointRateLimit", "functions-identity/src/domains/app-check/windowsAppCheck.ts"),
  listEncryptedProjectMemorySnapshots: readOnly("Lists the caller's snapshot metadata; no writes."),
  listHermesConnections: readOnly("Lists the caller's hermes_connections docs; no writes."),
  listHermesGatewayClients: readOnly("Lists the caller's gateway client rows; no writes."),
  listKnowledgeRepos: readOnly("Lists the caller's knowledge repos and manifests; no writes."),
  listLinuxAppCheckDevices: readOnly("Lists enrollment review material below the caller's namespace; no writes."),
  listPendingCloudVaultRotationRequirements: readOnly(
    "Trusted-device read of pending rotation requirements; no writes.",
  ),
  listPiAgentConnections: readOnly("Lists the caller's pi_agent_connections docs; no writes."),
  listRecovery: readOnly("Lists the caller's recovery methods; no writes."),
  mintBurnbarAttachmentPartURL: bulkSync(
    "Multipart part-URL minting is bounded by partIndex < the attachment's chunkCount (<= FILE_CAP_BYTES/32MiB parts per attachment); a counter doc would add a write per uploaded part.",
  ),
  mintLinuxAppCheckToken: enforced("checkPublicHttpEndpointRateLimit", "functions-identity/src/domains/app-check/linuxAppCheck.ts"),
  mintWindowsAppCheckToken: enforced("checkPublicHttpEndpointRateLimit", "functions-identity/src/domains/app-check/windowsAppCheck.ts"),
  performElderWandHostedSearch: limited(
    "mutation",
    "Calls a paid hosted-search provider per query; owner-funded spend is already bounded by the claimSearch per-tier run quota.",
  ),
  promoteTeamMember: enforced("checkTeamRosterMutationRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  publishAgentGrantAuthority: limited(
    "security",
    "Publishes the device authority envelope that gates agent capability grants.",
  ),
  publishIrohPairingPublicKey: limited(
    "security",
    "Publishes an iroh pairing public key under the caller's trust namespace.",
  ),
  publishIrohPairingRecord: limited(
    "security",
    "Writes the signed iroh pairing record that joins phone, host, and controller.",
  ),
  publishMissionApprovalCeiling: limited(
    "security",
    "Writes the approval ceiling policy for a mission — an agent-authority grant.",
  ),
  publishPhoneControlAuthority: limited(
    "security",
    "Publishes the phone-control authority envelope gated by a fresh device approval.",
  ),
  publishRelaySenderKey: limited(
    "security",
    "Publishes a relay sender key bound to the device's current Signal identity.",
  ),
  publishSignalPrekeyBundle: limited(
    "security",
    "Creates signed/one-time/kyber prekey docs — prekey publication is credential material.",
  ),
  pullLinuxCloudReplicas: bulkSync(
    "Replica pull is a bounded read capped at MAX_PULL_LIMIT=500 docs per call; a counter doc write on every pull would add write amplification the guideline forbids on sync paths.",
  ),
  purgeKnowledgeMemory: limited(
    "destructive",
    "Purges the caller's knowledge memory domain — a domain-wide purge.",
  ),
  purgeLegacyKnowledgeVectors: limited(
    "destructive",
    "Sweeps and deletes legacy plaintext vector fields account-wide.",
  ),
  pushLinuxCloudReplicas: bulkSync(
    "Replica push commits up to MAX_MUTATIONS=200 mutations plus a cursor update per call; a counter doc would add a write to every high-frequency sync push.",
  ),
  queryConversations: readOnly("Bounded conversation query path; no writes."),
  queueAgentCapabilityGrantRequest: limited(
    "security",
    "Queues a signed agent-capability grant request under the caller's authority envelope.",
  ),
  rebuildUsageRollups: limited(
    "mutation",
    "Rebuilds the caller's usage rollup docs; internal rebuild cooldowns bound cost but not call volume.",
  ),
  recordSignalRotation: limited(
    "security",
    "Records a Signal key rotation — credential-material mutation.",
  ),
  recordSignalSession: limited(
    "security",
    "Records a Signal session establishment — credential-material mutation.",
  ),
  recordTeamRewrapComplete: enforced("checkTeamRosterMutationRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  recordTeamSlugKeyId: enforced("checkTeamRosterMutationRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  refreshProviderAccountQuota: enforced("checkRefreshRateLimit", "functions-identity/src/callables/providerQuotaRefresh.ts"),
  refreshProviderQuota: enforced("checkRefreshRateLimit", "functions-identity/src/callables/providerQuotaRefresh.ts"),
  redeemMissionApprovalAnswer: limited(
    "security",
    "Redeems a mission approval answer — grant redemption; failure lockouts bound retries only.",
  ),
  registerBrowserEscrowDevice: limited(
    "security",
    "Registers a browser escrow device and fans out approval pushes to companion devices.",
  ),
  registerEscrowDevice: limited(
    "security",
    "Registers an escrow device into the trust graph and fans out approval pushes to companion devices.",
  ),
  registerIrohControllerRoute: limited(
    "security",
    "Consumes a signed challenge and registers a controller route generation.",
  ),
  registerLinuxAppCheckDevice: enforced("checkPublicHttpEndpointRateLimit", "functions-identity/src/domains/app-check/linuxAppCheckDevices.ts"),
  registerPasskey: limited(
    "security",
    "Writes a WebAuthn registration challenge; passkey enrollment is a credential ceremony.",
  ),
  removeTeamMember: enforced("checkTeamRosterMutationRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  repairTrustedSignalIdentity: limited(
    "security",
    "Consumes a repair challenge to rewire the trusted Signal identity — credential mutation.",
  ),
  requestKnowledgeResync: limited(
    "mutation",
    "Marks the caller's knowledge repos needsResync (bounded by the 200-repo listing).",
  ),
  reserveAgentControlActionBudget: limited(
    "mutation",
    "Writes an action-budget reservation under the caller's allowance ledger.",
  ),
  reserveFlooRelayBudget: limited(
    "mutation",
    "Writes a Floo relay budget reservation under the caller's allowance ledger.",
  ),
  resolveActiveIrohControllerRoutes: readOnly(
    "Fail-closed trust-graph route resolution; transaction performs reads only.",
  ),
  respondHermesGatewayApproval: limited(
    "security",
    "Resolves a gateway approval request — a device-grant decision.",
  ),
  respondMissionApproval: limited(
    "security",
    "Resolves a mission approval request — grant approval; failure lockouts bound retries only.",
  ),
  restoreHostedQuotaEntitlement: limited(
    "mutation",
    "Writes a fresh hosted-quota entitlement doc during reinstall restore.",
  ),
  revokeAllAccess: limited(
    "destructive",
    "Panic path: revokes all devices, sessions, and provider credentials account-wide.",
  ),
  revokeEscrowDeviceTrust: limited(
    "security",
    "Revokes an escrow device's trust and cascades the grant/authority cleanup.",
  ),
  revokeHermesConnection: enforced("checkHermesRateLimit", "functions-media/src/domains/hermes/hermes.ts"),
  revokeHermesGatewayClient: limited(
    "security",
    "Revokes a gateway client and deletes its token index entry.",
  ),
  revokeIrohControllerRoute: limited(
    "security",
    "Advances a controller route's generation to revoke it — device-trust mutation.",
  ),
  revokeIrohPairingRecord: limited(
    "security",
    "Revokes a signed iroh pairing record — pairing mutation.",
  ),
  revokeLinuxAppCheckDevice: limited(
    "security",
    "Irreversibly revokes a Linux device key inside a nonce-bound transaction.",
  ),
  revokePiAgentConnection: enforced("checkPiAgentRateLimit", "functions-identity/src/domains/identity/piAgent.ts"),
  revokeProviderAccountDeviceLink: limited(
    "security",
    "Removes a provider-account device link — device-trust mutation.",
  ),
  revokeRemoteMcpClient: limited(
    "security",
    "Revokes a remote-MCP client grant — credential revocation.",
  ),
  rotateCloudVaultKey: limited(
    "security",
    "Rotates the account's CloudVault key and creates the rewrap job.",
  ),
  rotateHermesGatewayClientToken: limited(
    "security",
    "Rotates a gateway client bearer token — credential rotation.",
  ),
  rotateTeamKey: enforced("checkTeamRosterMutationRateLimit", "functions-identity/src/domains/identity/teamRosterCallables.ts"),
  scanLegacyPlaintextArtifacts: readOnly(
    "Scans the caller's artifact metadata for legacy plaintext flags; returns IDs only, no writes.",
  ),
  searchEncryptedConversationIndex: readOnly("Encrypted-index query path; no writes."),
  searchKnowledge: enforced("checkKnowledgeSearchRateLimit", "functions-sync/src/domains/knowledge/knowledgeSearch.ts"),
  listKnowledgeChunks: enforced("checkKnowledgeSearchRateLimit", "functions-sync/src/domains/knowledge/knowledgeSearch.ts"),
  searchStreams: readOnly("Searches the caller's remote-MCP stream catalog; no writes."),
  seedAndroidDemoAccount: limited(
    "mutation",
    "Seeds demo data under the caller's account; owner-scoped writes.",
  ),
  setHermesGatewayOversightMode: limited(
    "mutation",
    "Writes the oversight-mode flag on a caller-owned gateway client.",
  ),
  setupRecovery: limited(
    "security",
    "Writes a recovery method record — recovery setup is a security ceremony.",
  ),
  confirmRecovery: limited(
    "security",
    "Confirms a recovery method against the stored verification hash.",
  ),
  signalActivationReadiness: readOnly(
    "Reads escrow devices and identity keys to report activation readiness; no writes.",
  ),
  signalPrekeyWatermark: readOnly("Reads prekey counts to report the low-water mark; no writes."),
  submitAgentNotificationReply: enforced("checkAgentNotificationReplyRateLimit", "functions-sync/src/domains/notify/agentNotifications.ts"),
  submitBugReport: {
    kind: "limited",
    tier: "external-side-effect",
    limits: { burst: { windowSeconds: 600, maxAttempts: 3 }, sustained: { windowSeconds: 86_400, maxAttempts: 10 } },
    reason:
      "Each report creates a Linear issue, posts to Slack, and queues a commandsAllowed/fileEditsAllowed agent mission; 3 per 10 min / 10 per day keeps triage usable while capping the heaviest fan-out on the callable surface.",
  },
  submitDomainCoreShadowSamples: bulkSync(
    "Shadow-sample ingest is capped at DOMAIN_CORE_SHADOW_MAX_BATCH=100 samples per call; a counter doc would add a write to every high-frequency evidence flush.",
  ),
  ticketBurnbarAttachmentDownload: limited(
    "mutation",
    "Mints a download URL but also meters the caller's outbound quota doc — a write, not read-only.",
  ),
  triggerVoIPCall: enforced("checkVoIPCallRateLimit", "functions-media/src/domains/push/voipPush.ts"),
  updateCliAgentMissionStatus: perObjectBounded(
    "Only the claiming host (hostWriteNonce) can move its own mission through the HOST_STATUS_TRANSITIONS state machine; mission creation is limited by checkMissionCreateRateLimit.",
  ),
  updateHermesConnectionStatus: enforced("checkHermesRateLimit", "functions-media/src/domains/hermes/hermes.ts"),
  updatePiAgentConnectionStatus: enforced("checkPiAgentRateLimit", "functions-identity/src/domains/identity/piAgent.ts"),
  updateProviderAccount: limited(
    "mutation",
    "Updates caller-owned provider account metadata; no credential material changes.",
  ),
  uploadProviderQuotaSnapshot: bulkSync(
    "Quota snapshot upload writes one quota_snapshots doc plus one provider_accounts update per call; a counter doc would add a write per periodic provider sync.",
  ),
  validateMediaPurchase: readOnly(
    "Retired path — rejects every call with failed-precondition before any write.",
  ),
  validateOpenTimestampsProof: limited(
    "security",
    "Nonce-gated OTS proof validation against the configured verifier; part of the high-risk computer-use ceremony.",
  ),
  verifyAuditLog: readOnly("Verifies the caller's audit chain head; no writes."),
  verifyCloudProTopUp: limited(
    "mutation",
    "Verifies an App Store top-up JWS and writes the caller's entitlement.",
  ),
  verifyGooglePlayBurnBarProSubscription: limited(
    "mutation",
    "Verifies a Google Play subscription and writes an idempotent billing record.",
  ),
  verifyGooglePlayCloudProTopUp: limited(
    "mutation",
    "Verifies a Google Play top-up and writes an idempotent billing record.",
  ),
  verifyHostedQuotaEntitlement: limited(
    "mutation",
    "Verifies an App Store JWS and reconciles the caller's entitlement doc.",
  ),
  verifyPasskeyAssertion: limited(
    "security",
    "Consumes a passkey assertion challenge and updates credential sign state.",
  ),
  verifyPasskeyRegistration: limited(
    "security",
    "Consumes a registration challenge and creates a passkey credential.",
  ),
  writeSignalAtRestDocument: limited(
    "security",
    "Writes validated Signal envelopes under the caller's path allowlist — credential-adjacent mutation.",
  ),
} as const satisfies Record<string, CallableRatePolicy>;

export function resolveCallableRatePolicy(name: string): CallableRatePolicy | undefined {
  return (CALLABLE_RATE_POLICIES as Record<string, CallableRatePolicy>)[name];
}
