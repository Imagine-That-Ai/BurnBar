import { Banner } from '../../components/Banner.js';
import { useSupportStore } from '../../state/supportStore.js';

const INCLUDED = [
  'Daemon health summary and protocol version',
  'Redacted config paths (no secrets)',
  'Perf sample names and timings from this session',
  'Desktop session hints (XDG session type)',
  'Tray degradation flag'
];

const EXCLUDED = [
  'Provider API tokens and refresh material',
  'Socket auth payloads and gateway secrets',
  'Raw provider log bodies',
  'Account sync ciphertext'
];

export function DiagnosticsExportCard() {
  const exportState = useSupportStore((s) => s.exportState);
  const exportPath = useSupportStore((s) => s.exportPath);
  const exportError = useSupportStore((s) => s.exportError);
  const exportDiagnostics = useSupportStore((s) => s.exportDiagnostics);

  return (
    <section className="p09-diagnostics-card" aria-labelledby="p09-diagnostics-heading">
      <h3 id="p09-diagnostics-heading">Diagnostics export</h3>
      <p className="muted">
        Writes a redacted JSON bundle through the packaged save dialog. Review what is included before
        sharing.
      </p>
      <div className="p09-manifest">
        <p>
          <strong>Included</strong>
        </p>
        <ul className="p09-manifest-list">
          {INCLUDED.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
        <p>
          <strong>Excluded</strong>
        </p>
        <ul className="p09-manifest-list p09-manifest-excluded">
          {EXCLUDED.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </div>
      <div className="actions">
        <button
          type="button"
          className="primary"
          disabled={exportState === 'exporting'}
          onClick={() => void exportDiagnostics()}
        >
          {exportState === 'exporting' ? 'Exporting…' : 'Export redacted diagnostics'}
        </button>
      </div>
      <div className="p09-export-status" aria-live="polite" aria-atomic="true">
        {exportState === 'exporting' ? <p>Export in progress…</p> : null}
        {exportState === 'success' && exportPath ? (
          <p className="p09-export-success">
            <strong>Export written:</strong> <span className="mono">{exportPath}</span>
          </p>
        ) : null}
      </div>
      {exportState === 'failed' && exportError ? (
        <Banner tone="degraded" role="alert">
          {exportError}
        </Banner>
      ) : null}
    </section>
  );
}