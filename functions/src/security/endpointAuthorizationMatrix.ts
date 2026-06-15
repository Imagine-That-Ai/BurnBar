type EndpointTrigger = "callable" | "http" | "scheduled" | "firestore-trigger" | "provider-webhook";

type EndpointAuthorizationEntry = {
  exportedName: string;
  trigger: EndpointTrigger;
  authMethod: string;
  appCheck: "required" | "not-applicable" | "not-required";
  tenantSource: string;
  objectIdsFromClient: string[];
  ownershipCheck: string;
  negativeBolaTest: string;
  highRiskComputerUse: boolean;
  actionKind?: string;
  publicJustification?: string;
  notes?: string;
};

type MatrixDefaults = Omit<
  EndpointAuthorizationEntry,
  "exportedName" | "objectIdsFromClient" | "highRiskComputerUse" | "actionKind"
> & {
  objectIdsFromClient?: string[];
  highRiskComputerUse?: boolean;
  actionKind?: string;
};

function entries(names: string[], defaults: MatrixDefaults): EndpointAuthorizationEntry[] {
  return names.map((exportedName) => {
    const { highRiskComputerUse, actionKind, ...rest } = defaults;
    return {
      exportedName,
      objectIdsFromClient: rest.objectIdsFromClient ?? [],
      highRiskComputerUse: highRiskComputerUse === true,
      ...(actionKind !== undefined ? { actionKind } : {}),
      ...rest,
    };
  });
}

const publicHealth = entries(["healthCheck", "healthLive", "healthReady"], {
  trigger: "http",
  authMethod: "public health probe",
  appCheck: "not-required",
  tenantSource: "none",
  ownershipCheck: "no tenant data returned",
  negativeBolaTest: "not-applicable-public-health",
  publicJustification: "Read-only health endpoints expose no user objects.",
});

const scheduledJobs = entries(
  [
    "rollupIrohTransportDaily",
    "recomputeMediaQuotaUsage",
    "rollupMediaSessionDaily",
    "evaluateMediaBudget",
    "evaluateComputerUseBudget",
    "computeTierCogsDaily",
    "recomputeComputerUseQuotaUsage",
    "rollupComputerUseDaily",
    "retryStuckVoIPPushes",
    "retryStuckFcmPushes",
    "retryStuckAgentReplyEvents",
    "purgeLegacyKnowledgeVectorsScheduled",
    "reconcileKnowledgeMemoryDaily",
    "detectStalePendingCloudVaultRotations",
    "backfillProviderAccountDeviceLinksScheduled",
    "onUsageWritten",
    "rebuildRollups",
    "refreshAllProviderQuotas",
    "refreshModelLandscapeBenchmarks",
    "anchorAuditLogHeads",
    "latestRouterRundown",
    "reconcileHostedEntitlementsDaily",
    "backfillPrivacyPlaintextScheduled",
    "reapHermesGatewayApprovals",
  ],
  {
    trigger: "scheduled",
    authMethod: "Cloud Scheduler / platform trigger",
    appCheck: "not-applicable",
    tenantSource: "job-owned collection scans",
    ownershipCheck: "server-side collection filters and per-document uid fields",
    negativeBolaTest: "not-applicable-platform-trigger",
  },
);

const firestoreTriggers = entries(
  ["onCliSessionAgentReplyNotification", "onMobileAssistantAgentReplyNotification", "onKnowledgeRepoPush"],
  {
    trigger: "firestore-trigger",
    authMethod: "Firestore event trigger",
    appCheck: "not-applicable",
    tenantSource: "event document path",
    ownershipCheck: "server derives uid/object path from triggering document",
    negativeBolaTest: "not-applicable-platform-trigger",
  },
);

const providerWebhooks = entries(["stripeBurnBarProWebhook", "appStoreServerNotificationsV2"], {
  trigger: "provider-webhook",
  authMethod: "provider signature / signed notification verifier",
  appCheck: "not-applicable",
  tenantSource: "provider-signed account token or transaction payload",
  ownershipCheck: "server maps verified provider account token to uid/entitlement",
  negativeBolaTest: "provider-webhook-signature-and-account-token-tests",
  publicJustification:
    "Provider webhook endpoints are internet-facing by design and authenticated by provider signatures.",
});

const codePairingCallables = entries(
  [
    "startCliLink",
    "pollCliLink",
    "completeCliLink",
    "createHermesPairing",
    "completeHermesPairing",
    "createPiAgentPairing",
    "completePiAgentPairing",
  ],
  {
    trigger: "callable",
    authMethod: "Firebase Auth/App Check plus one-time pairing or link code",
    appCheck: "required",
    tenantSource: "request auth uid and pairing/link session",
    objectIdsFromClient: ["pairingId", "code", "sessionId"],
    ownershipCheck: "pairing/link session belongs to authenticated uid or one-time secret/code",
    negativeBolaTest:
      "functions/src/__tests__/phoneControlPairingBinding.test.ts; functions/src/__tests__/hermesGatewayKeyImmutability.test.ts; functions/src/__tests__/irohPairingFreshness.test.ts",
  },
);

const gatewayHttp = entries(["burnBarHermesGateway"], {
  trigger: "http",
  authMethod: "Hermes Gateway bearer token plus Ed25519 proof-of-possession",
  appCheck: "not-applicable",
  tenantSource: "token index resolves uid and clientId",
  objectIdsFromClient: ["messageId", "eventId", "attachmentId", "clientId", "destinationId"],
  ownershipCheck: "resolveGatewayGrant checks active client, scope, expiry, PoP, and uid/client namespace",
  negativeBolaTest:
    "functions/src/__tests__/hermesGatewayPopV2.test.ts; functions/src/__tests__/hermesGatewayAttachmentInit.test.ts",
});

const authScopedCallables = entries(
  [
    "insightsHostedAnswer",
    "grantMediaGrandfather",
    "validateMediaPurchase",
    "triggerVoIPCall",
    "reserveAgentControlActionBudget",
    "reserveFlooRelayBudget",
    "validateOpenTimestampsProof",
    "submitAgentNotificationReply",
    "connectProviderAccount",
    "connectProviderCredential",
    "connectHostedQuotaAccount",
    "connectSelfHostedQuotaAccount",
    "uploadProviderQuotaSnapshot",
    "deleteHostedQuotaCredentials",
    "updateProviderAccount",
    "deleteProviderAccount",
    "deleteUserCloudData",
    "deleteProviderCredential",
    "refreshProviderAccountQuota",
    "refreshProviderQuota",
    "listHermesConnections",
    "revokeHermesConnection",
    "updateHermesConnectionStatus",
    "getHermesGatewayAttachmentDownloadUrl",
    "approveHermesGatewayDeviceGrant",
    "listHermesGatewayClients",
    "revokeHermesGatewayClient",
    "rotateHermesGatewayClientToken",
    "enqueueHermesGatewayEvent",
    "setHermesGatewayOversightMode",
    "respondHermesGatewayApproval",
    "listPiAgentConnections",
    "revokePiAgentConnection",
    "updatePiAgentConnectionStatus",
    "createStripeBurnBarProCheckoutSession",
    "createStripeBurnBarProPortalSession",
    "verifyGooglePlayBurnBarProSubscription",
    "verifyGooglePlayCloudProTopUp",
    "beginEncryptedSessionBlobUpload",
    "getEncryptedSessionBlobDownloadUrl",
    "commitEncryptedSearchIndexBatch",
    "commitEncryptedProjectMemorySnapshot",
    "getEncryptedProjectMemorySnapshot",
    "listEncryptedProjectMemorySnapshots",
    "searchEncryptedConversationIndex",
    "queryConversations",
    "getProfileAvatarDownloadUrl",
    "commitKnowledgeBatch",
    "configureKnowledgeSource",
    "deleteKnowledgeSource",
    "purgeKnowledgeMemory",
    "purgeLegacyKnowledgeVectors",
    "connectKnowledgeRepo",
    "disconnectKnowledgeRepo",
    "listKnowledgeRepos",
    "requestKnowledgeResync",
    "publishSignalPrekeyBundle",
    "claimSignalPrekeyBundle",
    "recordSignalSession",
    "recordSignalRotation",
    "signalPrekeyWatermark",
    "signalActivationReadiness",
    "rotateCloudVaultKey",
    "listPendingCloudVaultRotationRequirements",
    "getDataDomainUsage",
    "searchKnowledge",
    "exportUserData",
    "deleteDomainData",
    "setupRecovery",
    "confirmRecovery",
    "listRecovery",
    "consumeCredentialTransfer",
    "revokeAllAccess",
    "getAuditLog",
    "verifyAuditLog",
    "registerBrowserEscrowDevice",
    "registerPasskey",
    "verifyPasskeyRegistration",
    "beginPasskeyAssertion",
    "verifyPasskeyAssertion",
    "issueRemoteMcpGrant",
    "revokeRemoteMcpClient",
    "searchStreams",
    "bindAppCheckAttestation",
    "issueHighRiskActionNonce",
    "registerEscrowDevice",
    "approveEscrowDeviceTrust",
    "revokeEscrowDeviceTrust",
    "publishIrohPairingPublicKey",
    "publishIrohPairingRecord",
    "revokeIrohPairingRecord",
    "publishPhoneControlAuthority",
    "publishRelaySenderKey",
    "publishAgentGrantAuthority",
    "queueAgentCapabilityGrantRequest",
    "respondMissionApproval",
    "rebuildUsageRollups",
    "seedAndroidDemoAccount",
    "adoptProviderAccountForDevice",
    "revokeProviderAccountDeviceLink",
    "backfillProviderAccountDeviceLinks",
    "beginEntitlementBinding",
    "verifyHostedQuotaEntitlement",
    "verifyCloudProTopUp",
    "restoreHostedQuotaEntitlement",
    "backfillPrivacyPlaintext",
  ],
  {
    trigger: "callable",
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["clientId", "deviceId", "documentID", "providerAccountId", "sourceId", "attachmentId"],
    ownershipCheck:
      "handler must derive uid from request.auth.uid and validate object path or owner uid before Admin SDK access",
    negativeBolaTest:
      "functions/src/__tests__/misc.test.ts; functions/src/__tests__/stripe.test.ts; functions/src/__tests__/hermesGatewayPopV2.test.ts; functions/src/__tests__/hermesGatewayAttachmentInit.test.ts; functions/src/__tests__/projectMemoryDocId.test.ts; functions/src/__tests__/knowledgeMemoryDedupHash.test.ts; functions/src/__tests__/submitAgentNotificationReply.test.ts; functions/src/__tests__/highRiskOwnerActionCallableGuards.test.ts; firestore-rules-tests/computer-use.test.js; firestore-rules-tests/session-log-backup.test.js",
  },
);

const outboundServiceJobs = entries(["sendVoIPOutbound", "sendFcmOutbound"], {
  trigger: "callable",
  authMethod: "Firebase Auth/App Check plus server-side push entitlement checks",
  appCheck: "required",
  tenantSource: "request.auth.uid and registered device token owner",
  objectIdsFromClient: ["deviceId", "notificationId"],
  ownershipCheck: "push target must be owned by authenticated uid or server-generated event",
  negativeBolaTest:
    "functions/src/__tests__/voipPushMetadata.test.ts; functions/src/__tests__/submitAgentNotificationReply.test.ts",
});

const HIGH_RISK_ENDPOINTS: Record<string, string> = {
  approveHermesGatewayDeviceGrant: "hermes_gateway_device_grant_approve",
  connectProviderAccount: "provider_account_connect",
  connectProviderCredential: "provider_credential_connect",
  connectHostedQuotaAccount: "hosted_quota_account_connect",
  connectSelfHostedQuotaAccount: "self_hosted_quota_account_connect",
  exportUserData: "data_export",
  deleteUserCloudData: "user_cloud_data_delete",
  revokeAllAccess: "revoke_all_access",
  updateProviderAccount: "provider_account_update",
  revokeRemoteMcpClient: "remote_mcp_grant_revoke",
  deleteHostedQuotaCredentials: "hosted_quota_credential_delete",
  deleteProviderAccount: "provider_account_delete",
  completeHermesPairing: "hermes_pairing_complete",
  completePiAgentPairing: "pi_agent_pairing_complete",
};

export const endpointAuthorizationMatrix: EndpointAuthorizationEntry[] = [
  ...publicHealth,
  ...scheduledJobs,
  ...firestoreTriggers,
  ...providerWebhooks,
  ...codePairingCallables,
  ...gatewayHttp,
  ...authScopedCallables,
  ...outboundServiceJobs,
]
  .map((entry) => {
    const actionKind = HIGH_RISK_ENDPOINTS[entry.exportedName];
    if (actionKind) {
      return { ...entry, highRiskComputerUse: true, actionKind };
    }
    return entry;
  })
  .sort((left, right) => left.exportedName.localeCompare(right.exportedName));

export function endpointAuthorizationByName(): Map<string, (typeof endpointAuthorizationMatrix)[number]> {
  return new Map(endpointAuthorizationMatrix.map((entry) => [entry.exportedName, entry]));
}
