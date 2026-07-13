import { useState } from 'react';
import type { LinuxUpdateStatus } from '../../tauriBridge.js';
import { useShellStore } from '../../state/shellStore.js';

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
    : status?.state === 'available' || status?.state === 'current'
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
                      onClick={() => void copyCommand(action.id, action.command!)}
                      aria-label={`Copy ${action.id} command`}
                    >
                      {copiedAction === action.id ? 'Copied' : 'Copy command'}
                    </button>
                  ) : null}
                </div>
              ))}
            </div>
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
          <button type="button" onClick={() => void openArtifact()} disabled={!bridge?.openUpdateUrl}>
            Open signed download
          </button>
        ) : null}
      </div>
    </section>
  );
}
