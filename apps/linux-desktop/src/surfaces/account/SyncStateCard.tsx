import type { AccountStatus, LinuxCloudSyncStatus } from '../../tauriBridge.js';

const CANONICAL_INVARIANT = 'Local SQLite remains canonical';

function formatRelativeSync(iso: string): string {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return iso;
  const deltaSec = Math.max(0, Math.floor((Date.now() - then) / 1000));
  if (deltaSec < 60) return 'just now';
  const mins = Math.floor(deltaSec / 60);
  if (mins < 60) return `${mins} min ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 48) return `${hours} hr ago`;
  const days = Math.floor(hours / 24);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}

function syncHeadline(status: AccountStatus, cloudSync?: LinuxCloudSyncStatus | null): string {
  if (!status.signedIn) {
    return 'Local-only';
  }
  switch (cloudSync?.phase) {
    case 'disabled':
      return 'Cloud sync off';
    case 'locked':
      return 'Sync keyring locked';
    case 'backoff':
      return 'Sync retry pending';
    case 'syncing':
      return 'Encrypted sync in progress';
    default:
      break;
  }
  switch (status.syncState) {
    case 'active':
      return 'Encrypted sync active';
    case 'paused':
      return 'Sync paused';
    default:
      return 'Local-only';
  }
}

function syncDetail(status: AccountStatus, cloudSync?: LinuxCloudSyncStatus | null): string {
  if (!status.signedIn) {
    return 'Cloud identity is optional. Your workspace stays on this machine until you sign in elsewhere.';
  }
  if (cloudSync?.phase === 'disabled') {
    return 'Cloud consent is off. Local rows remain canonical and no new encrypted sync is attempted.';
  }
  if (cloudSync?.phase === 'locked') {
    return 'Unlock the Linux keyring before encrypted sync can run. Local rows remain canonical while it is locked.';
  }
  switch (status.syncState) {
    case 'active':
      return 'Private rows sync when you opt in; encrypted payloads never replace the on-disk canonical store.';
    case 'paused':
      return 'Encrypted private rows stay on disk locally until you resume sync.';
    default:
      return 'Signed in without active sync—local rows stay authoritative on this device.';
  }
}

export function SyncStateCard({
  status,
  cloudSync,
  syncBusy = false,
  syncError,
  onSync
}: {
  status: AccountStatus;
  cloudSync?: LinuxCloudSyncStatus | null;
  syncBusy?: boolean;
  syncError?: string | null;
  onSync?: () => void;
}) {
  const stateClass = status.signedIn ? status.syncState : 'local-only';
  const cloudSyncLabel = cloudSync?.phase === 'syncing'
    ? 'Syncing…'
    : cloudSync?.phase === 'locked'
      ? 'Keyring locked'
      : cloudSync?.phase === 'backoff'
        ? 'Retry pending'
        : cloudSync?.phase === 'disabled'
          ? 'Cloud sync off'
          : cloudSync?.phase === 'ready'
            ? 'Ready'
            : 'Unavailable';

  return (
    <section
      className={`sync-state-card sync-state-card--${stateClass}`}
      aria-labelledby="sync-state-title"
    >
      <h3 id="sync-state-title">{syncHeadline(status, cloudSync)}</h3>
      <p className="sync-state-detail muted">{syncDetail(status, cloudSync)}</p>
      <p className="sync-canonical-invariant" data-testid="canonical-invariant">
        {CANONICAL_INVARIANT}
      </p>
      {status.signedIn && status.syncState === 'active' && status.lastSyncAt ? (
        <p className="sync-last muted" role="status">
          Last sync {formatRelativeSync(status.lastSyncAt)}
        </p>
      ) : null}
      {status.signedIn && cloudSync ? (
        <div className="sync-daemon-posture" data-testid="cloud-sync-posture">
          <p className="sync-last muted" role="status">
            Daemon sync: <strong>{cloudSyncLabel}</strong>
            {cloudSync.pendingMutationCount > 0
              ? ` · ${cloudSync.pendingMutationCount} pending change${cloudSync.pendingMutationCount === 1 ? '' : 's'}`
              : ' · no pending changes'}
          </p>
          {cloudSync.consecutiveFailures > 0 ? (
            <p className="sync-last muted" role="status">
              {cloudSync.consecutiveFailures} consecutive sync failure{cloudSync.consecutiveFailures === 1 ? '' : 's'}.
            </p>
          ) : null}
          {onSync ? (
            <button
              type="button"
              className="ghost"
              onClick={onSync}
              disabled={syncBusy || !cloudSync.vaultKeyAvailable || cloudSync.phase === 'disabled'}
              aria-busy={syncBusy}
            >
              {syncBusy ? 'Syncing…' : 'Sync now'}
            </button>
          ) : null}
          {syncError ? <p className="sync-last" role="alert">{syncError}</p> : null}
        </div>
      ) : null}
    </section>
  );
}
