/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * Extracted from src/types/legacy.ts (the strangler "leftovers" bucket) and
 * grouped by domain. Re-exported verbatim from src/types/legacy.ts so every
 * existing `import ... from "../types/legacy"` keeps resolving unchanged.
 */

// ---------------------------------------------------------------------------
// Provider identity
// ---------------------------------------------------------------------------

/** Stable lowercase catalog/provider key used by provider accounts. */
export type ProviderID = string;

/** Supported provider kinds. */
export const SUPPORTED_PROVIDERS = [
  "openai",
  "minimax",
  "zai",
  "kimi",
  "factory",
  "cursor",
  "claude-code",
  "codex",
  "opencode",
  "antigravity",
  "xai",
  "mimo",
  "openburnbar",
] as const;

export type Provider = (typeof SUPPORTED_PROVIDERS)[number];

/** Providers that support backend quota refresh. */
export const BACKEND_REFRESH_PROVIDERS: readonly Provider[] = [
  "openai",
  "minimax",
  "zai",
  "kimi",
  "factory",
  "cursor",
  "xai",
  "mimo",
];

/** Providers that are treated as local-only (no backend refresh). */
export const LOCAL_ONLY_PROVIDERS: readonly Provider[] = ["claude-code", "codex", "opencode", "antigravity"];

// ---------------------------------------------------------------------------
// Credential kinds
// ---------------------------------------------------------------------------

export type CredentialKind = "token" | "bearer" | "session" | "cookie" | "plan";

export type ProviderAccountStatus = "connected" | "disconnected" | "stale" | "error" | "disabled" | "deleted";

export type ProviderAccountStorageScope = "cloud_refreshable" | "local_only" | "device_keychain" | "server_private";

export type ProviderAccountRefreshState = "connected" | "refreshing" | "stale" | "error" | "disabled" | "local_only";

export interface ProviderAccountCredentialDescriptor {
  credentialKind: CredentialKind;
  storageScope: ProviderAccountStorageScope;
  redactedLabel: string;
}

// ---------------------------------------------------------------------------
// Firestore: provider_accounts/{accountID}
// ---------------------------------------------------------------------------

export interface ProviderAccountDoc {
  /** Stable account ID unique within a user namespace. */
  id: string;

  /** Canonical provider key from the catalog/cloud contract. */
  providerID: ProviderID;

  /** User-visible account label, e.g. "Work" or "Personal". */
  label: string;

  /** Optional non-secret identity hint such as email/org/team name. */
  identityHint?: string;

  status: ProviderAccountStatus;
  credentialKind: CredentialKind;
  storageScope: ProviderAccountStorageScope;

  /** Redacted display label only. Raw secrets and secret refs are forbidden. */
  redactedLabel: string;

  /** Device that owns a local-only credential/session, if any. */
  sourceDeviceID?: string;

  /** Optional switcher/browser/CLI profile linkage. Not a credential. */
  linkedSwitcherProfileID?: string;

  isDefault: boolean;
  sortKey: number;
  lastValidatedAt?: string;
  lastRefreshAt?: string;
  lastErrorCode?: string;
  /** Endpoint profile for multi-host providers (e.g. mimo.token-plan.sgp). */
  endpointProfileID?: string;
  /** Regional cluster for Token Plan accounts. */
  region?: "cn" | "sgp" | "ams" | "global";
  /** Token Plan tier when vendor quota API is unavailable. */
  tokenPlanTier?: "lite" | "standard" | "pro" | "max";
  /** Token Plan billing cycle for credit-cap math. */
  tokenPlanBillingCycle?: "monthly" | "annual";
  /** Auth wizard method id (mimo-token-plan, mimo-payg, …). */
  authMethodID?: string;
  schemaVersion: number;
  createdAt: string;
  updatedAt: string;
}

// ---------------------------------------------------------------------------
// Firestore: provider_account_device_links/{accountID}_{deviceID}
// ---------------------------------------------------------------------------

export type DeviceLinkCapability = "owner" | "use" | "add";
export type DeviceLinkStatus = "active" | "revoked";

export type ProviderAccountDeviceLinkDoc = Omit<
  import("../generated/device-links.js").ProviderAccountDeviceLinkDoc,
  "capability" | "status"
> & {
  capability: DeviceLinkCapability;
  status: DeviceLinkStatus;
};

// ---------------------------------------------------------------------------
// Firestore: runtime_connection_preferences/{deviceID}_{runtimeKind}
// ---------------------------------------------------------------------------

export type RuntimeConnectionPreferenceKind = "hermes" | "piAgent";

export interface RuntimeConnectionPreferenceDoc {
  id: string;
  deviceID: string;
  runtimeKind: RuntimeConnectionPreferenceKind;
  selectedConnectionID: string;
  selectedInstanceID?: string;
  selectedModelID?: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Firestore: provider_account_secret_refs/{uid}_{accountID} (server-private)
// ---------------------------------------------------------------------------

export interface ProviderAccountSecretRefDoc {
  uid: string;
  providerID: ProviderID;
  accountID: string;
  secretVersionName: string;
  createdAt: string;
  updatedAt: string;
}

// ---------------------------------------------------------------------------
// Firestore: provider_connections/{provider}
// ---------------------------------------------------------------------------

export interface ProviderConnectionDoc {
  /** Provider key (e.g. "minimax"). */
  provider: Provider;

  /** Connection lifecycle status. */
  status: "connected" | "disconnected" | "error" | "stale";

  /** ISO 8601 timestamp of last successful validation. */
  lastValidatedAt?: string;

  /** ISO 8601 timestamp of last quota refresh. */
  lastRefreshAt?: string;

  /** Last known error code from a refresh or validation attempt. */
  lastErrorCode?: string;

  /** Kind of credential stored in the vault. */
  credentialKind: CredentialKind;

  /** Redacted human-readable label (e.g. "minimax_***abcd"). */
  redactedLabel: string;

  /** Schema version for forward-compatible migrations. */
  schemaVersion: number;

  /** Optional warning message shown to the user (e.g. session TTL). */
  warningMessage?: string;
}
