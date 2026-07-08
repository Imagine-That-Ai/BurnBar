import type { ProviderCatalogEntry, QuotaBucketState } from '../../tauriBridge.js';

export type ProviderAccountStorageScope = 'cloud' | 'local' | 'keychain' | 'unknown';
export type ProviderAccountStatus = 'connected' | 'stale' | 'error';

const STORAGE_LABEL: Record<ProviderAccountStorageScope, string> = {
  cloud: 'Cloud',
  local: 'Local',
  keychain: 'Mac Keychain',
  unknown: 'Storage'
};

const STATUS_LABEL: Record<ProviderAccountStatus, string> = {
  connected: 'Connected',
  stale: 'Stale',
  error: 'Needs attention'
};

export function storageLabel(scope: ProviderAccountStorageScope): string {
  return STORAGE_LABEL[scope];
}

export function statusLabel(status: ProviderAccountStatus): string {
  return STATUS_LABEL[status];
}

export function inferStorageScope(
  accountLabel: string,
  explicit?: ProviderAccountStorageScope
): ProviderAccountStorageScope {
  if (explicit) return explicit;
  const lower = accountLabel.toLowerCase();
  if (lower.includes('keychain') || lower.includes('mac')) return 'keychain';
  if (lower.includes('workspace') || lower.includes('team') || lower.includes('cloud')) return 'cloud';
  if (lower.includes('personal') || lower.includes('local')) return 'local';
  return 'unknown';
}

export function inferAccountStatus(
  buckets: { state: QuotaBucketState }[],
  explicit?: ProviderAccountStatus
): ProviderAccountStatus {
  if (explicit) return explicit;
  if (buckets.some((b) => b.state === 'missing_credential')) return 'error';
  if (buckets.some((b) => b.state === 'exhausted' || b.state === 'cooling_down')) return 'stale';
  return 'connected';
}

export type ProviderCardMeta = {
  storage: ProviderAccountStorageScope;
  status: ProviderAccountStatus;
  quotaSource?: string;
  quotaConfidence?: 'high' | 'medium' | 'low' | 'stale';
};

export function resolveProviderCardMeta(provider: ProviderCatalogEntry): ProviderCardMeta {
  const ext = provider as ProviderCatalogEntry & {
    accountStorage?: ProviderAccountStorageScope;
    accountStatus?: ProviderAccountStatus;
    quotaSource?: string;
    quotaConfidence?: 'high' | 'medium' | 'low' | 'stale';
  };
  return {
    storage: inferStorageScope(provider.accountLabel, ext.accountStorage),
    status: inferAccountStatus(provider.quotaBuckets, ext.accountStatus),
    quotaSource: ext.quotaSource,
    quotaConfidence: ext.quotaConfidence
  };
}