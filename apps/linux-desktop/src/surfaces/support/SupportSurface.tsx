import { useMemo, useSyncExternalStore, type ReactNode } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { listPerfSamples } from '../../perfMarks.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSupportStore } from '../../state/supportStore.js';
import { Sparkline } from '../../components/Sparkline.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { SystemStatusSection } from '../SystemStatusSection.js';
import { DiagnosticsExportCard } from './DiagnosticsExportCard.js';
import { VersionGrid } from './VersionGrid.js';
import { MediaSection } from '../media/MediaSection.js';
import './support.css';

function usePerfSamples() {
  return useSyncExternalStore(
    (notify) => {
      const timer = setInterval(notify, 1000);
      return () => clearInterval(timer);
    },
    () => JSON.stringify(listPerfSamples())
  );
}

function groupPerfSamples(samples: { name: string; ms: number }[]) {
  const map = new Map<string, number[]>();
  for (const s of samples) {
    const list = map.get(s.name) ?? [];
    list.push(s.ms);
    map.set(s.name, list);
  }
  return [...map.entries()].map(([name, values]) => ({ name, values, latest: values[values.length - 1] }));
}

export function SupportSurface() {
  const samplesJson = usePerfSamples();
  const samples = JSON.parse(samplesJson) as { name: string; ms: number }[];
  const grouped = useMemo(() => groupPerfSamples(samples), [samples]);
  const trayDegraded = useShellStore((s) => s.trayDegraded);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const setFixtureMode = useShellStore((s) => s.setFixtureMode);
  const status = useDaemonStatusCopy();
  const versionInfo = useSupportStore((s) => s.versionInfo);
  const versionLoading = useSupportStore((s) => s.versionLoading);
  const versionError = useSupportStore((s) => s.versionError);
  const loadVersion = useSupportStore((s) => s.loadVersion);

  useLaneLoad(loadVersion);

  let versionBlock: ReactNode;
  if (versionLoading && !versionInfo) {
    versionBlock = <p className="muted">Loading version facts…</p>;
  } else if (versionError && !versionInfo) {
    versionBlock = (
      <OfflineNotice
        status={status}
        summary="Support can still export diagnostics when the packaged shell is available."
        fixtureMode={fixtureMode}
      />
    );
  } else if (versionInfo) {
    versionBlock = <VersionGrid info={versionInfo} />;
  } else {
    versionBlock = (
      <OfflineNotice
        status={status}
        summary="Enable fixture mode or use the packaged shell for version facts."
        fixtureMode={fixtureMode}
      />
    );
  }

  return (
    <>
      <SystemStatusSection showRawDiagnostic />
      {versionBlock}
      <DiagnosticsExportCard />
      <MediaSection />
      <table className="table p09-perf-table">
        <thead>
          <tr>
            <th>Perf sample</th>
            <th>ms</th>
            <th>Trend</th>
          </tr>
        </thead>
        <tbody>
          {grouped.map((row) => (
            <tr key={row.name}>
              <td>{row.name}</td>
              <td>{row.latest.toFixed(1)}</td>
              <td>
                <Sparkline values={row.values} label={`${row.name} perf trend`} />
              </td>
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
