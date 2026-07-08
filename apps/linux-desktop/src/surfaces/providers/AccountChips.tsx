import {
  inferAccountStatus,
  inferStorageScope,
  statusLabel,
  storageLabel,
  type ProviderAccountStatus,
  type ProviderAccountStorageScope
} from './providerAccountVisual.js';
import type { QuotaBucketState } from '../../tauriBridge.js';

export function AccountChips({
  accountLabel,
  buckets,
  storage,
  status
}: {
  accountLabel: string;
  buckets: { state: QuotaBucketState }[];
  storage?: ProviderAccountStorageScope;
  status?: ProviderAccountStatus;
}) {
  const storageScope = inferStorageScope(accountLabel, storage);
  const accountStatus = inferAccountStatus(buckets, status);

  return (
    <div
      className="provider-account-chip-rail"
      role="group"
      aria-label={`Account storage ${storageLabel(storageScope)}, status ${statusLabel(accountStatus)}`}
    >
      <span
        className="provider-account-chip provider-account-chip--storage"
        data-storage={storageScope}
        title={accountLabel.trim() || storageLabel(storageScope)}
      >
        {storageLabel(storageScope)}
      </span>
      <span
        className="provider-account-chip provider-account-chip--status"
        data-status={accountStatus}
      >
        {statusLabel(accountStatus)}
      </span>
    </div>
  );
}