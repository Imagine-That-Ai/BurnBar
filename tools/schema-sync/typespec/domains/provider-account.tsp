/**
 * Provider account Firestore contracts and connect metadata.
 * Collection: users/{uid}/provider_accounts/{accountID}
 */
namespace OpenBurnBar.Firestore.ProviderAccount;

/** Firestore: users/{uid}/provider_accounts/{accountID} */
model ProviderAccountDoc {
  id: string;
  providerID: string;
  label: string;
  identityHint?: string;
  status: string;
  credentialKind: string;
  storageScope: string;
  redactedLabel: string;
  sourceDeviceID?: string;
  linkedSwitcherProfileID?: string;
  isDefault: boolean;
  sortKey: int32;
  lastValidatedAt?: string;
  lastRefreshAt?: string;
  lastErrorCode?: string;
  endpointProfileID?: string;
  region?: string;
  tokenPlanTier?: string;
  tokenPlanBillingCycle?: string;
  authMethodID?: string;
  schemaVersion: int32;
  createdAt: string;
  updatedAt: string;
}

/** Connect wizard / adapter context for endpoint-profile providers. */
model ProviderAccountConnectContext {
  endpointProfileID?: string;
  region?: string;
  tokenPlanTier?: string;
  tokenPlanBillingCycle?: string;
  authMethodID?: string;
}
