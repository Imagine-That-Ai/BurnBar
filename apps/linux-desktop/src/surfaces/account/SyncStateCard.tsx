import type { AccountStatus } from '../../tauriBridge.js';

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

function syncHeadline(status: AccountStatus): string {
  if (!status.signedIn) {
    return 'Local-only';
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

function syncDetail(status: AccountStatus): string {
  if (!status.signedIn) {
    return 'Cloud identity is optional. Your workspace stays on this machine until you sign in elsewhere.';
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

export function SyncStateCard({ status }: { status: AccountStatus }) {
  const stateClass = status.signedIn ? status.syncState : 'local-only';

  return (
    <section
      className={`sync-state-card sync-state-card--${stateClass}`}
      aria-labelledby="sync-state-title"
    >
      <h3 id="sync-state-title">{syncHeadline(status)}</h3>
      <p className="sync-state-detail muted">{syncDetail(status)}</p>
      <p className="sync-canonical-invariant" data-testid="canonical-invariant">
        {CANONICAL_INVARIANT}
      </p>
      {status.signedIn && status.syncState === 'active' && status.lastSyncAt ? (
        <p className="sync-last muted" role="status">
          Last sync {formatRelativeSync(status.lastSyncAt)}
        </p>
      ) : null}
    </section>
  );
}