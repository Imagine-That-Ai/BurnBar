/**
 * Provider account Firestore contracts and connect metadata.
 * Collection: users/{uid}/provider_accounts/{accountID}
 */
namespace OpenBurnBar.Firestore.ProviderAccount;

union ProviderAccountStatus {
  connected: "connected",
  disconnected: "disconnected",
  stale: "stale",
  error: "error",
  disabled: "disabled",
  deleted: "deleted",
}

union CredentialKind {
  token: "token",
  bearer: "bearer",
  session: "session",
  cookie: "cookie",
  plan: "plan",
}

union ProviderAccountStorageScope {
  cloudRefreshable: "cloud_refreshable",
  localOnly: "local_only",
  deviceKeychain: "device_keychain",
  serverPrivate: "server_private",
}

/** Firestore: users/{uid}/provider_accounts/{accountID} */
model ProviderAccountDoc {
  id: string;
  providerID: string;
  label: string;
  identityHint?: string;
  status: ProviderAccountStatus;
  credentialKind: CredentialKind;
  storageScope: ProviderAccountStorageScope;
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
