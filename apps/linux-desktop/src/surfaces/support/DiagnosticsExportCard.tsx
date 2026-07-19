import { Banner } from '../../components/Banner.js';
import { useEffect, useRef } from 'react';
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

const FIXTURE_EXPORT_PATH = '/tmp/openburnbar-diagnostics-fixture.json';

/** Keep the preview useful without echoing arbitrary native metadata into the UI. */
function safeManifestLabel(entry: string, excluded: boolean): string {
  const normalized = entry.trim().toLowerCase();
  if (normalized.includes('shell') && normalized.includes('daemon') && normalized.includes('version')) {
    return 'Shell and daemon versions';
  }
  if (normalized.includes('health') && normalized.includes('protocol')) {
    return 'Daemon health summary and protocol version';
  }
  if (normalized.includes('package') && normalized.includes('runtime')) {
    return 'Package channel and runtime facts';
  }
  if (normalized.includes('schema') && normalized.includes('permission')) {
    return 'Export schema and owner-only file permissions';
  }
  if (normalized.includes('provider') && (normalized.includes('token') || normalized.includes('credential') || normalized.includes('key'))) {
    return 'Provider API tokens and refresh material';
  }
  if (normalized.includes('socket') && (normalized.includes('auth') || normalized.includes('token'))) {
    return 'Socket auth payloads and gateway secrets';
  }
  if (normalized.includes('provider') && normalized.includes('log')) {
    return 'Raw provider log bodies';
  }
  if (normalized.includes('account') && (normalized.includes('cipher') || normalized.includes('sync'))) {
    return 'Account sync ciphertext';
  }
  return excluded ? 'Sensitive fields (redacted)' : 'Diagnostic metadata (redacted)';
}

function safeManifest(entries: string[], excluded: boolean): string[] {
  return [...new Set(entries.map((entry) => safeManifestLabel(entry, excluded)))];
}

function presentExportError(error: string): string {
  if (/cancel|abort|closed/i.test(error)) return 'Export cancelled. No diagnostics file was written.';
  if (/unsafe path/i.test(error)) return 'Native diagnostics export returned an unsafe path.';
  if (/unsafe preview|invalid privacy metadata/i.test(error)) {
    return 'Native diagnostics export returned unsafe preview metadata.';
  }
  if (/packaged shell required/i.test(error)) return 'Packaged shell required to export diagnostics.';
  return 'Diagnostics export failed. Check the packaged shell status and try again.';
}

export function DiagnosticsExportCard() {
  const exportState = useSupportStore((s) => s.exportState);
  const exportPath = useSupportStore((s) => s.exportPath);
  const exportPreview = useSupportStore((s) => s.exportPreview);
  const exportError = useSupportStore((s) => s.exportError);
  const copyState = useSupportStore((s) => s.copyState);
  const copyError = useSupportStore((s) => s.copyError);
  const exportDiagnostics = useSupportStore((s) => s.exportDiagnostics);
  const copyDiagnosticsPath = useSupportStore((s) => s.copyDiagnosticsPath);
  const resetExport = useSupportStore((s) => s.resetExport);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const exportContext = useRef<{ bridge: typeof bridge; fixtureMode: boolean } | null>(null);
  useEffect(() => {
    const previous = exportContext.current;
    if (previous && (previous.bridge !== bridge || previous.fixtureMode !== fixtureMode)) {
      resetExport();
    }
    exportContext.current = { bridge, fixtureMode };
  }, [bridge, fixtureMode, resetExport]);
  const included = safeManifest(exportPreview?.included ?? INCLUDED, false);
  const excluded = safeManifest(exportPreview?.excluded ?? EXCLUDED, true);
  const fixtureExport = exportPath === FIXTURE_EXPORT_PATH;
  const previewSource = fixtureExport || (!exportPath && fixtureMode)
    ? 'fixture'
    : exportPath || bridge
      ? 'packaged'
      : 'browser-preview';
  const previewLabel = previewSource === 'fixture'
    ? 'Fixture preview'
    : previewSource === 'packaged'
      ? 'Packaged shell export'
      : 'Browser preview';

  return (
    <section className="p09-diagnostics-card" aria-labelledby="p09-diagnostics-heading">
      <h3 id="p09-diagnostics-heading">Diagnostics export</h3>
      <p className="muted">
        {previewSource === 'packaged'
          ? 'Opens a native save dialog for a redacted JSON bundle. Review what is included before sharing.'
          : previewSource === 'fixture'
            ? 'Shows redacted fixture metadata for host smoke tests. No native file is created.'
            : 'Run the packaged Linux shell to create a native redacted diagnostics bundle.'}
      </p>
      <div
        className={`p09-export-provenance p09-export-provenance--${previewSource}`}
        data-provenance={previewSource}
        role="status"
        aria-label="Diagnostics export provenance"
      >
        <strong>{previewLabel}</strong>
        <span>
          {previewSource === 'fixture'
            ? 'Synthetic metadata for host smoke tests; no file is written.'
            : previewSource === 'packaged'
              ? 'Native save destination with owner-only file permissions.'
              : 'No native export is available in browser preview.'}
        </span>
      </div>
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
              <dd>
                {previewSource === 'fixture'
                  ? 'Fixture metadata; no file written'
                  : previewSource === 'packaged'
                    ? 'Native export metadata'
                    : 'Preview metadata unavailable'}
              </dd>
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
          disabled={exportState === 'exporting' || (!fixtureMode && !bridge)}
          onClick={() => void exportDiagnostics()}
        >
          {exportState === 'exporting'
            ? 'Exporting…'
            : previewSource === 'fixture'
              ? 'Preview redacted diagnostics (fixture)'
              : previewSource === 'browser-preview'
                ? 'Export unavailable in browser preview'
              : 'Export redacted diagnostics'}
        </button>
      </div>
      <div className="p09-export-status" aria-live="polite" aria-atomic="true">
        {exportState === 'exporting' ? <p>Export in progress…</p> : null}
        {exportState === 'success' && exportPath ? (
          <div className="p09-export-success">
            <p>
              <strong>{fixtureExport ? 'Fixture preview path:' : 'Export written:'}</strong>{' '}
              <span className="mono">{exportPath}</span>
            </p>
            <button
              type="button"
              className="ghost"
              onClick={() => void copyDiagnosticsPath()}
              disabled={fixtureExport || copyState === 'copying'}
              aria-label={fixtureExport ? 'Copy diagnostics path unavailable for fixture preview' : 'Copy diagnostics path'}
            >
              {fixtureExport ? 'Copy unavailable (fixture)' : copyState === 'copying' ? 'Copying…' : 'Copy path'}
            </button>
            <p className="muted" aria-live="polite">
              {fixtureExport
                ? 'Fixture output is metadata only; no file was written.'
                : copyState === 'success'
                  ? 'Diagnostics path copied.'
                  : null}
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
          {presentExportError(exportError)}
        </Banner>
      ) : null}
    </section>
  );
}
