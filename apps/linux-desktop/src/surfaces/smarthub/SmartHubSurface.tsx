import { useState } from 'react';
import { useShellStore } from '../../state/shellStore.js';

type IoTAction = 'list' | 'status' | 'cast' | 'homeassistant';

/**
 * SmartHub / IoT surface — CLI-backed only until daemon methods exist (plan Phase 2/3).
 * Shell invokes `openburnbar-cli devices iot ...` via optional bridge helper when present.
 */
export function SmartHubSurface() {
  const bridge = useShellStore((s) => s.bridge);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const [action, setAction] = useState<IoTAction>('list');
  const [output, setOutput] = useState<string>('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function run() {
    setBusy(true);
    setError(null);
    if (fixtureMode) {
      setOutput(
        JSON.stringify(
          {
            fixture: true,
            action,
            devices: [{ id: 'pixelclock-1', kind: 'pixelclock', online: true }],
            note: 'Live control uses openburnbar-cli devices iot …'
          },
          null,
          2
        )
      );
      setBusy(false);
      return;
    }
    const runner = (bridge as { runCli?: (args: string[]) => Promise<string> } | null)?.runCli;
    if (!runner) {
      setError(
        'CLI bridge not available. Install openburnbar-cli and wire runCli, or run: openburnbar-cli devices iot list'
      );
      setBusy(false);
      return;
    }
    try {
      const args = ['devices', 'iot', action];
      const text = await runner(args);
      setOutput(text);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="surface-panel" aria-label="SmartHub">
      <header style={{ marginBottom: '1rem' }}>
        <h2 style={{ margin: 0 }}>SmartHub / IoT</h2>
        <p style={{ margin: '0.35rem 0 0', color: 'var(--color-text-mute)', fontSize: '0.85rem' }}>
          Control devices through <code>openburnbar-cli devices iot</code> — no invented{' '}
          <code>daemon.smarthub.*</code> methods.
        </p>
      </header>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.5rem', alignItems: 'center' }}>
        <label>
          Action{' '}
          <select value={action} onChange={(e) => setAction(e.target.value as IoTAction)}>
            <option value="list">list</option>
            <option value="status">status</option>
            <option value="cast">cast</option>
            <option value="homeassistant">homeassistant</option>
          </select>
        </label>
        <button type="button" onClick={() => void run()} disabled={busy}>
          {busy ? 'Running…' : 'Run CLI'}
        </button>
      </div>
      {error ? (
        <p role="alert" style={{ color: 'var(--color-seal-crimson)' }}>
          {error}
        </p>
      ) : null}
      <pre
        style={{
          marginTop: '1rem',
          padding: '0.75rem',
          borderRadius: 'var(--radius-md)',
          border: '1px solid var(--color-glass-line)',
          background: 'color-mix(in srgb, var(--color-glass-bg) 55%, transparent)',
          fontSize: '0.78rem',
          overflow: 'auto',
          minHeight: '8rem'
        }}
      >
        {output || 'Output appears here.'}
      </pre>
    </section>
  );
}
