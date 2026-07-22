import { Banner } from '../../components/Banner.js';
import { useShellStore } from '../../state/shellStore.js';
import { useSupportStore } from '../../state/supportStore.js';

const INCLUDED = [
  'Shell and daemon versions',
  'Daemon health summary and protocol version',
  'Package channel and runtime facts',
  'Export schema and owner-only file permissions'
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
  const exportPreview = useSupportStore((s) => s.exportPreview);
  const exportError = useSupportStore((s) => s.exportError);
  const copyState = useSupportStore((s) => s.copyState);
  const copyError = useSupportStore((s) => s.copyError);
  const exportDiagnostics = useSupportStore((s) => s.exportDiagnostics);
  const copyDiagnosticsPath = useSupportStore((s) => s.copyDiagnosticsPath);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const included = exportPreview?.included ?? INCLUDED;
  const excluded = exportPreview?.excluded ?? EXCLUDED;

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
          {included.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
        <p>
          <strong>Excluded</strong>
        </p>
        <ul className="p09-manifest-list p09-manifest-excluded">
          {excluded.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
        {exportPreview ? (
          <dl className="p09-export-preview" aria-label="Export privacy preview">
            <div>
              <dt>Preview</dt>
              <dd>{fixtureMode ? 'Fixture metadata; no file written' : 'Native export metadata'}</dd>
            </div>
            <div><dt>Bytes</dt><dd className="mono">{exportPreview.byteCount.toLocaleString()}</dd></div>
            <div><dt>File mode</dt><dd className="mono">{exportPreview.fileMode}</dd></div>
          </dl>
        ) : (
          <p className="muted p09-preview-unavailable">
            Export preview metadata will appear after the packaged shell writes a bundle.
          </p>
        )}
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
          <div className="p09-export-success">
            <p><strong>Export written:</strong> <span className="mono">{exportPath}</span></p>
            <button
              type="button"
              className="ghost"
              onClick={() => void copyDiagnosticsPath()}
              disabled={copyState === 'copying'}
              aria-label="Copy diagnostics path"
            >
              {copyState === 'copying' ? 'Copying…' : 'Copy path'}
            </button>
            <p className="muted" aria-live="polite">
              {copyState === 'success' ? 'Diagnostics path copied.' : null}
            </p>
          </div>
        ) : null}
      </div>
      {copyState === 'failed' && copyError ? (
        <Banner tone="degraded" role="alert">
          {copyError}
        </Banner>
      ) : null}
      {exportState === 'failed' && exportError ? (
        <Banner tone="degraded" role="alert">
          {exportError}
        </Banner>
      ) : null}
    </section>
  );
}
