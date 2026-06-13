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
  region?: "cn" | "sgp" | "ams" | "global";
  tokenPlanTier?: "lite" | "standard" | "pro" | "max";
  tokenPlanBillingCycle?: "monthly" | "annual";
  authMethodID?: string;
  schemaVersion: int32;
  createdAt: string;
  updatedAt: string;
}

/** Connect wizard / adapter context for endpoint-profile providers. */
model ProviderAccountConnectContext {
  endpointProfileID?: string;
  region?: "cn" | "sgp" | "ams" | "global";
  tokenPlanTier?: "lite" | "standard" | "pro" | "max";
  tokenPlanBillingCycle?: "monthly" | "annual";
  authMethodID?: string;
}
