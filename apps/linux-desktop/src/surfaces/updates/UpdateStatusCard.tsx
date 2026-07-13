import { useState } from 'react';
import type { LinuxUpdateStatus } from '../../tauriBridge.js';
import { useShellStore } from '../../state/shellStore.js';

function formatAge(seconds: number | undefined): string {
  if (seconds === undefined) return 'age unavailable';
  if (seconds < 60) return 'less than a minute ago';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours} hour${hours === 1 ? '' : 's'} ago`;
  const days = Math.floor(hours / 24);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}

export function UpdateStatusCard({
  status,
  loading,
  error,
  onCheck
}: {
  status: LinuxUpdateStatus | null;
  loading: boolean;
  error: string | null;
  onCheck: () => void;
}) {
  const bridge = useShellStore((state) => state.bridge);
  const [copiedAction, setCopiedAction] = useState<string | null>(null);
  const hasVerifiedFreshFeed = status?.signatureState === undefined
    || (status.signatureState === 'verified' && status.feedFreshness === 'fresh');
  const daemonAllowsPackageChange = status?.compatibility === undefined
    || status.compatibility.state === 'aligned';
  const packageActionsBlocked = !hasVerifiedFreshFeed || !daemonAllowsPackageChange;
  const openArtifact = async () => {
    if (!status?.artifact?.url || !bridge?.openUpdateUrl) return;
    await bridge.openUpdateUrl(status.artifact.url);
  };
  const copyCommand = async (id: string, command: string) => {
    try {
      if (!navigator.clipboard?.writeText) throw new Error('clipboard_unavailable');
      await navigator.clipboard.writeText(command);
      setCopiedAction(id);
      window.setTimeout(() => setCopiedAction((current) => current === id ? null : current), 2200);
    } catch {
      setCopiedAction(null);
    }
  };

  const heading = loading
    ? 'Checking signed channel'
    : status?.state === 'available'
      ? `OpenBurnBar ${status.latestVersion} is available`
      : status?.state === 'current'
        ? 'OpenBurnBar is up to date'
        : status?.state === 'invalid'
          ? 'Update metadata rejected'
          : 'Update channel unavailable';
  const detail = error
    ?? status?.reason
    ?? (status?.state === 'available'
      ? 'The feed signature and artifact metadata match the pinned Linux release key.'
      : status?.state === 'current'
        ? 'The signed feed does not contain a newer version for this architecture.'
        : 'The signed update channel has not returned a usable result.');
  const verificationLabel = loading
    ? 'Verifying signed feed'
    : status?.signatureState === 'verified'
      ? 'Ed25519 verified feed'
      : status?.state === 'invalid'
        ? 'Signature or schema rejected'
        : 'Signed channel status';

  return (
    <section
      className={`p09-update-status p09-update-status--${status?.state ?? 'unavailable'}`}
      aria-labelledby="p09-update-status-title"
      role={status?.state === 'invalid' ? 'alert' : 'status'}
      aria-busy={loading}
    >
      <div>
        <p className="p09-update-status__eyebrow">{verificationLabel}</p>
        <h3 id="p09-update-status-title">{heading}</h3>
        <p>{detail}</p>
        {status?.notes ? <p className="muted">{status.notes}</p> : null}
        {status?.feedFreshness === 'stale' ? (
          <p className="p09-update-freshness p09-update-freshness--stale" role="alert">
            Signed metadata is older than seven days ({formatAge(status.feedAgeSeconds)}). Check again before
            changing packages.
          </p>
        ) : status?.feedFreshness === 'future' ? (
          <p className="p09-update-freshness p09-update-freshness--stale" role="alert">
            Signed metadata is dated in the future; the native verifier will not treat it as fresh.
          </p>
        ) : status?.feedFreshness === 'fresh' ? (
          <p className="p09-update-freshness" aria-label="Feed freshness">
            Feed published {formatAge(status.feedAgeSeconds)} · signature verified
          </p>
        ) : null}
        {status?.compatibility?.state === 'mismatch' ? (
          <p className="p09-update-freshness p09-update-freshness--stale" role="alert">
            {status.compatibility.reason}
          </p>
        ) : status?.compatibility?.state === 'unknown' ? (
          <p className="p09-update-freshness" role="status">
            Daemon version is unavailable; install guidance remains read-only until the daemon reconnects.
          </p>
        ) : null}
        {status?.artifact ? (
          <dl className="p09-update-artifact">
            <div><dt>Package</dt><dd>{status.artifact.type} · {status.artifact.architecture}</dd></div>
            <div><dt>SHA-256</dt><dd className="mono">{status.artifact.sha256.slice(0, 16)}…</dd></div>
          </dl>
        ) : null}
        {status?.instructions ? (
          <div className="p09-update-instructions" aria-label="Package update and rollback guidance">
            <p className="p09-update-instructions__title">
              Linux-native {status.instructions.packageManager} actions
            </p>
            <div className="p09-update-instruction-list">
              {[status.instructions.install, status.instructions.rollback, status.instructions.restart].map((action) => (
                <div className="p09-update-instruction" data-update-action={action.id} key={action.id}>
                  <div>
                    <strong>{action.label}</strong>
                    <p>{action.instruction}</p>
                    {action.command ? <code>{action.command}</code> : null}
                  </div>
                  {action.command ? (
                    <button
                      type="button"
                      className="ghost"
                      disabled={action.id !== 'restart' && (!action.available || packageActionsBlocked)}
                      onClick={() => void copyCommand(action.id, action.command!)}
                      aria-label={`Copy ${action.id} command`}
                    >
                      {copiedAction === action.id
                        ? 'Copied'
                        : action.id !== 'restart' && (!action.available || packageActionsBlocked)
                          ? 'Unavailable'
                          : 'Copy command'}
                    </button>
                  ) : null}
                </div>
              ))}
            </div>
            {packageActionsBlocked && status.state === 'available' ? (
              <p className="muted p09-update-instructions__note" role="status">
                Install and rollback guidance is disabled until a fresh verified feed and aligned daemon are
                available. Restart guidance remains available for recovery.
              </p>
            ) : null}
            <p className="muted p09-update-instructions__note" aria-live="polite">
              The shell never runs package-manager commands or replaces distro-owned files.
            </p>
          </div>
        ) : null}
      </div>
      <div className="p09-update-status__actions">
        <button type="button" className="ghost" onClick={onCheck} disabled={loading}>
          {loading ? 'Checking…' : 'Check again'}
        </button>
        {status?.state === 'available' && status.artifact ? (
          <button
            type="button"
            onClick={() => void openArtifact()}
            disabled={!bridge?.openUpdateUrl || packageActionsBlocked}
          >
            {packageActionsBlocked ? 'Download unavailable' : 'Open signed download'}
          </button>
        ) : null}
      </div>
    </section>
  );
}
