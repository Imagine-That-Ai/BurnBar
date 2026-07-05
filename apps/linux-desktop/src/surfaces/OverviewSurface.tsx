import { displayLinuxSocketPath, displayLinuxSupportDir } from '../shellPaths.js';
import { useShellStore } from '../state/shellStore.js';
import { DaemonDataSection } from './DaemonDataSection.js';

export function OverviewSurface() {
  const refreshHealth = useShellStore((s) => s.refreshHealth);
  const healthBusy = useShellStore((s) => s.healthBusy);
  return (
    <>
      <dl className="fact-grid">
        <div className="fact">
          <dt>Data dir</dt>
          <dd className="mono">{displayLinuxSupportDir()}</dd>
        </div>
        <div className="fact">
          <dt>Socket</dt>
          <dd className="mono">{displayLinuxSocketPath()}</dd>
        </div>
      </dl>
      <div className="actions">
        <button type="button" className="primary" disabled={healthBusy} onClick={() => void refreshHealth()}>
          {healthBusy ? 'Reconnecting…' : 'Reconnect'}
        </button>
      </div>
      <DaemonDataSection route="overview" label="Overview" />
    </>
  );
}
