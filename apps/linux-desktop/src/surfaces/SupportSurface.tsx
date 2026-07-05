import { useSyncExternalStore } from 'react';
import { listPerfSamples } from '../perfMarks.js';
import { useShellStore } from '../state/shellStore.js';
import { SystemStatusSection } from './SystemStatusSection.js';

// Perf samples are appended outside React; snapshot by length+route render.
function usePerfSamples() {
  return useSyncExternalStore(
    (notify) => {
      const timer = setInterval(notify, 1000);
      return () => clearInterval(timer);
    },
    () => JSON.stringify(listPerfSamples())
  );
}

export function SupportSurface() {
  const samplesJson = usePerfSamples();
  const samples = JSON.parse(samplesJson) as { name: string; ms: number }[];
  const trayDegraded = useShellStore((s) => s.trayDegraded);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const setFixtureMode = useShellStore((s) => s.setFixtureMode);
  return (
    <>
      <SystemStatusSection showRawDiagnostic />
      <table className="table">
        <thead>
          <tr>
            <th>Perf sample</th>
            <th>ms</th>
          </tr>
        </thead>
        <tbody>
          {samples.map((s, i) => (
            <tr key={`${s.name}-${i}`}>
              <td>{s.name}</td>
              <td>{s.ms.toFixed(1)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {trayDegraded ? <p className="muted">Tray degraded: use window reopen from launcher.</p> : null}
      <div className="actions">
        <button type="button" className="ghost" onClick={() => setFixtureMode(!fixtureMode)}>
          {fixtureMode ? 'Disable daemon fixture' : 'Enable daemon fixture (host smoke)'}
        </button>
      </div>
    </>
  );
}
