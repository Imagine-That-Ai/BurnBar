import { useCallback, useEffect, useState } from 'react';
import { fixtureIntegrationsStatus } from '../../daemonFixture.js';
import { useShellStore } from '../../state/shellStore.js';
import type {
  IntegrationStatus,
  SmartHubCommandResult,
  SmartHubOperation,
  SmartHubStatusResult
} from '../../tauriBridge.js';
import './smarthub.css';

const OPERATIONS: ReadonlyArray<{ value: SmartHubOperation; label: string }> = [
  { value: 'discover', label: 'Discover SmartHub bridge' },
  { value: 'status', label: 'SmartHub status and control probe' },
  { value: 'cast_status', label: 'Google Cast status' },
  { value: 'homeassistant_status', label: 'Home Assistant status' },
  { value: 'parity', label: 'All integration status' }
];

function fixtureCommand(operation: SmartHubOperation): SmartHubCommandResult {
  if (operation === 'parity') {
    return { operation, payload: fixtureIntegrationsStatus() };
  }
  if (operation === 'discover') {
    return {
      operation,
      payload: [
        {
          adapter: 'smart_hub_bridge',
          serviceType: '_openburnbar-peer._tcp',
          instances: ['OpenBurnBar-fixture'],
          rawTranscript: 'fixture transcript; no live network access'
        }
      ]
    };
  }
  const adapter = operation === 'cast_status'
    ? 'google_cast'
    : operation === 'homeassistant_status'
      ? 'home_assistant'
      : 'smart_hub_bridge';
  const payload: SmartHubStatusResult = {
    adapter,
    status: 'fixture_capability',
    details: {
      adapter,
      status: 'fixture_capability',
      note: 'Live status is available from the packaged trusted CLI.'
    }
  };
  return { operation, payload };
}

function StatusDetails({ payload }: { payload: SmartHubStatusResult }) {
  const entries = Object.entries(payload.details).filter(
    ([key]) => key !== 'adapter' && key !== 'status' && key !== 'blocker'
  );
  return (
    <div className="smarthub-status-result">
      <p className="smarthub-status-heading">
        <strong>{payload.adapter}</strong>
        <span aria-label={`Status: ${payload.status}`}>{payload.status}</span>
      </p>
      {payload.blocker ? <p className="smarthub-blocker">{payload.blocker}</p> : null}
      <dl className="smarthub-detail-list">
        {entries.map(([key, value]) => (
          <div key={key}>
            <dt>{key.replaceAll('_', ' ')}</dt>
            <dd>{value || '—'}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

function IntegrationRows({ rows }: { rows: IntegrationStatus[] }) {
  return (
    <ul className="smarthub-integration-list">
      {rows.map((row) => (
        <li key={`${row.kind}-${row.label}`} className="smarthub-integration-row">
          <span>
            <strong>{row.label}</strong>
            <small>{row.detail}</small>
          </span>
          <span className={`smarthub-state smarthub-state--${row.state}`}>{row.state}</span>
        </li>
      ))}
    </ul>
  );
}

/**
 * SmartHub / IoT surface backed by the fixed Linux CLI contract.
 *
 * There is deliberately no generic shell bridge here. The packaged Tauri
 * command accepts only the five operations above and returns bounded JSON;
 * fixture output is labeled so it cannot be mistaken for live device proof.
 */
export function SmartHubSurface() {
  const bridge = useShellStore((s) => s.bridge);
  const bridgeReady = useShellStore((s) => s.bridgeReady);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const [operation, setOperation] = useState<SmartHubOperation>('status');
  const [result, setResult] = useState<SmartHubCommandResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const run = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      if (fixtureMode) {
        setResult(fixtureCommand(operation));
        return;
      }
      if (!bridge) {
        throw new Error('Packaged shell and trusted openburnbar-cli are required for SmartHub status.');
      }
      if (bridge.smartHubCommand) {
        setResult(await bridge.smartHubCommand(operation));
        return;
      }
      // Older packaged shells can still render the all-integration status;
      // they must not silently fall back to arbitrary CLI execution.
      if (operation === 'parity') {
        setResult({ operation, payload: await bridge.integrationsStatus() });
        return;
      }
      throw new Error('This packaged shell does not expose the typed SmartHub command contract.');
    } catch (err) {
      setResult(null);
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }, [bridge, fixtureMode, operation]);

  useEffect(() => {
    if (bridgeReady) void run();
  }, [bridgeReady, run]);

  return (
    <section className="surface-panel smarthub-surface" aria-label="SmartHub / IoT">
      <header className="smarthub-header">
        <h2>SmartHub / IoT</h2>
        <p>
          Linux device discovery and status use the packaged <code>openburnbar-cli devices</code> contract.
          The renderer sends no device-specific inputs or arbitrary shell arguments.
        </p>
      </header>
      <div className="smarthub-controls">
        <label htmlFor="smarthub-operation">Operation</label>
        <select
          id="smarthub-operation"
          value={operation}
          onChange={(event) => setOperation(event.target.value as SmartHubOperation)}
          disabled={busy}
        >
          {OPERATIONS.map((item) => (
            <option key={item.value} value={item.value}>
              {item.label}
            </option>
          ))}
        </select>
        <button type="button" onClick={() => void run()} disabled={busy || !bridgeReady}>
          {busy ? 'Checking…' : 'Run operation'}
        </button>
      </div>
      {busy ? <p role="status" aria-busy="true">Checking Linux device capability…</p> : null}
      {error ? <p role="alert">{error}</p> : null}
      {result ? (
        <div className="smarthub-result" aria-live="polite">
          <p className="smarthub-source">
            Data source: {fixtureMode ? 'fixture transcript (not live device proof)' : 'trusted packaged CLI'}
          </p>
          {result.operation === 'discover' ? (
            <div>
              <h3>Discovery</h3>
              {result.payload.length === 0 ? (
                <p>No SmartHub bridge instances were discovered.</p>
              ) : (
                <ul>
                  {result.payload.flatMap((row) =>
                    row.instances.map((instance) => <li key={`${row.adapter}-${instance}`}>{instance}</li>)
                  )}
                </ul>
              )}
              <p className="smarthub-muted">Service: {result.payload[0]?.serviceType ?? 'unknown'}</p>
            </div>
          ) : result.operation === 'parity' ? (
            <div>
              <h3>Integration status</h3>
              <IntegrationRows rows={result.payload.integrations} />
            </div>
          ) : (
            <div>
              <h3>{result.operation === 'status' ? 'SmartHub bridge' : result.payload.adapter}</h3>
              <StatusDetails payload={result.payload} />
            </div>
          )}
        </div>
      ) : !busy && !error && !bridgeReady ? (
        <p role="status">Checking the Linux runtime contract…</p>
      ) : null}
    </section>
  );
}
