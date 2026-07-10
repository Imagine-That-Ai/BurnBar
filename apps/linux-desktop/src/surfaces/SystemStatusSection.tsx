import { GlassAlert, daemonToneToSeverity } from '../components/GlassAlert.js';
import { FailureStateList } from '../components/FailureStateList.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';

const SHARED_FAILURE_CASES = [
  {
    id: 'secret-store',
    title: 'Secret Service locked or unavailable',
    recovery:
      'Open Settings -> Privacy & Security, unlock GNOME Keyring/KWallet, or set the headless passphrase file.',
    severity: 'error' as const,
    iconGlyph: '⛨'
  },
  {
    id: 'network-offline',
    title: 'Network offline',
    recovery: 'Provider catalog, sync, and update checks pause locally; reconnect then retry from Support.',
    severity: 'warning' as const,
    iconGlyph: '◎'
  },
  {
    id: 'permission-denied',
    title: 'Provider path permission denied',
    recovery: 'Review XDG provider log paths and grant read access only to the selected directories.',
    severity: 'error' as const,
    iconGlyph: '⊘'
  }
];

/**
 * Shared daemon alert + failure-state chips for settings/account/support.
 */
export function SystemStatusSection({ showRawDiagnostic = false }: { showRawDiagnostic?: boolean }) {
  const health = useShellStore((s) => s.health);
  const subscriptionState = useShellStore((s) => s.subscriptionState);
  const subscriptionError = useShellStore((s) => s.subscriptionError);
  const lastDaemonEventAt = useShellStore((s) => s.lastDaemonEventAt);
  const status = useDaemonStatusCopy();

  const connected = Boolean(health?.ok);
  const refreshDegraded = subscriptionState === 'error' || subscriptionState === 'offline';
  const refreshDescription = subscriptionState === 'pull'
    ? `Data refresh uses bounded AF_UNIX pull cadence${lastDaemonEventAt ? `; last event ${new Date(lastDaemonEventAt).toLocaleString()}` : ''}.`
    : subscriptionState === 'live'
      ? `Daemon event delivery is live${lastDaemonEventAt ? `; last event ${new Date(lastDaemonEventAt).toLocaleString()}` : ''}.`
      : subscriptionState === 'offline'
        ? 'Data refresh is paused while the network is offline and will resume automatically.'
        : subscriptionState === 'error'
          ? `Daemon health succeeded, but data refresh is retrying: ${subscriptionError ?? 'unknown subscription error'}`
          : 'Daemon health probe succeeded; the data refresh supervisor is starting.';

  return (
    <>
      <GlassAlert
        severity={connected && !refreshDegraded ? 'info' : connected ? 'warning' : daemonToneToSeverity(status.tone)}
        title={connected ? refreshDegraded ? 'Connected; data refresh degraded' : 'Connected to local peer' : status.label}
        description={
          connected
            ? refreshDescription
            : status.detail
        }
        iconGlyph={connected ? '⎔' : undefined}
        role="alert"
        className={connected && !refreshDegraded ? 'banner ok' : 'banner degraded'}
      >
        {showRawDiagnostic && status.rawDetail ? (
          <p className="glass-alert-description mono diagnostic-detail">{`Raw diagnostic: ${status.rawDetail}`}</p>
        ) : null}
      </GlassAlert>
      <FailureStateList cases={SHARED_FAILURE_CASES} />
    </>
  );
}
