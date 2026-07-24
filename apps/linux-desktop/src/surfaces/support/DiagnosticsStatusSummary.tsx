import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';

type SummaryRow = {
  label: string;
  value: string;
};

function safeDaemonVersion(value: string | undefined, fixtureMode: boolean): string {
  if (!value) return fixtureMode ? '0.1.0-fixture' : 'Not reported';
  return /^(?:v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)$/.test(value)
    ? value
    : 'Reported (redacted)';
}

/**
 * A deliberately small, safe-to-share health summary.  The daemon error and
 * socket path are useful to native logs, but neither belongs in a support
 * surface that a user may screenshot or paste into a ticket.
 */
export function DiagnosticsStatusSummary() {
  const health = useShellStore((state) => state.health);
  const bridge = useShellStore((state) => state.bridge);
  const bridgeReady = useShellStore((state) => state.bridgeReady);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const healthBusy = useShellStore((state) => state.healthBusy);
  const refreshHealth = useShellStore((state) => state.refreshHealth);
  const subscriptionState = useShellStore((state) => state.subscriptionState);
  const status = useDaemonStatusCopy();

  const source = fixtureMode
    ? 'Fixture data (host smoke only)'
    : bridge
      ? 'Packaged Linux shell'
      : 'Browser preview';
  const connection = health?.ok
    ? 'Connected'
    : fixtureMode
      ? 'Fixture health available'
      : bridgeReady && bridge
        ? 'Daemon unavailable'
        : 'Packaged shell unavailable';
  const refresh = subscriptionState === 'live'
    ? 'Live'
    : subscriptionState === 'pull'
      ? 'Bounded pull'
      : subscriptionState === 'offline'
        ? 'Paused (offline)'
        : subscriptionState === 'error'
          ? 'Retrying'
          : 'Starting';
  const daemonVersion = safeDaemonVersion(health?.daemonVersion, fixtureMode);
  const stateLabel = health?.ok
    ? `Daemon ${daemonVersion}${fixtureMode ? ' (fixture)' : ''}`
    : status.label;

  const rows: SummaryRow[] = [
    { label: 'Connection', value: connection },
    { label: 'Daemon version', value: daemonVersion },
    { label: 'Protocol', value: health?.protocolVersion ? `v${health.protocolVersion}` : 'Not reported' },
    { label: 'Data refresh', value: refresh },
    { label: 'Data source', value: source }
  ];

  const description = health?.ok
    ? 'The local daemon health probe succeeded. This summary omits socket paths, credentials, and raw error text.'
    : fixtureMode
      ? 'Synthetic daemon data is enabled for host smoke tests; it does not represent a packaged installation.'
      : bridge
        ? 'The packaged shell is present, but the local daemon did not report healthy. Check the daemon service and retry.'
        : 'This browser preview cannot probe the packaged daemon. Install and launch the Linux app for live facts.';
  const canReconnect = !fixtureMode && Boolean(bridge) && !health?.ok;

  return (
    <section
      className="p09-diagnostic-summary"
      aria-labelledby="p09-diagnostic-summary-heading"
      aria-live="polite"
      data-provenance={fixtureMode ? 'fixture' : bridge ? 'packaged' : 'browser-preview'}
    >
      <div className="p09-diagnostic-summary__header">
        <div>
          <h3 id="p09-diagnostic-summary-heading">Daemon diagnostics summary</h3>
          <p className="muted">{description}</p>
        </div>
        <span className={`p09-diagnostic-summary__state p09-diagnostic-summary__state--${status.tone}`}>
          {stateLabel}
        </span>
      </div>
      <dl className="p09-diagnostic-summary__facts" aria-label="Redacted daemon health facts">
        {rows.map((row) => (
          <div className="p09-diagnostic-summary__fact" key={row.label}>
            <dt>{row.label}</dt>
            <dd>{row.value}</dd>
          </div>
        ))}
      </dl>
      {canReconnect ? (
        <div className="p09-diagnostic-summary__actions">
          <p className="muted">Retry the local daemon health probe after starting or unlocking the daemon.</p>
          <button
            type="button"
            className="primary"
            onClick={() => void refreshHealth()}
            disabled={healthBusy}
            aria-busy={healthBusy}
          >
            {healthBusy ? 'Reconnecting…' : 'Reconnect'}
          </button>
        </div>
      ) : null}
    </section>
  );
}
