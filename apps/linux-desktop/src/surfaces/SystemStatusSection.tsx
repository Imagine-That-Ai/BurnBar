import { Banner } from '../components/Banner.js';
import { FailureStateList } from '../components/FailureStateList.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';

const SHARED_FAILURE_CASES = [
  {
    id: 'secret-store',
    title: 'Secret Service locked or unavailable',
    recovery: 'Open Settings -> Privacy & Security, unlock GNOME Keyring/KWallet, or set the headless passphrase file.'
  },
  {
    id: 'network-offline',
    title: 'Network offline',
    recovery: 'Provider catalog, sync, and update checks pause locally; reconnect then retry from Support.'
  },
  {
    id: 'permission-denied',
    title: 'Provider path permission denied',
    recovery: 'Review XDG provider log paths and grant read access only to the selected directories.'
  }
];

/**
 * Shared daemon banner + failure-state rows for settings/account/support.
 * `showRawDiagnostic` adds the redacted raw error line (Support only).
 */
export function SystemStatusSection({ showRawDiagnostic = false }: { showRawDiagnostic?: boolean }) {
  const health = useShellStore((s) => s.health);
  const status = useDaemonStatusCopy();
  return (
    <>
      <Banner tone="degraded" role="alert">
        {health?.ok ? 'Connected to local peer.' : `${status.label}: ${status.detail}`}
        {showRawDiagnostic && status.rawDetail ? (
          <p className="diagnostic-detail">{`Raw diagnostic: ${status.rawDetail}`}</p>
        ) : null}
      </Banner>
      <FailureStateList cases={SHARED_FAILURE_CASES} />
    </>
  );
}
