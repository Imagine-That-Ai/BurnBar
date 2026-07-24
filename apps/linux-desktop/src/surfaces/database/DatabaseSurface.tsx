import { useCallback, useEffect, useRef, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type { DatabaseWorkspaceFile } from '../../tauriBridge.js';
import { formatBytes } from '../system/systemFormat.js';
import { CodeRetrievalPanel } from './CodeRetrievalPanel.js';
import {
  recoveryActionLabel,
  recoveryImportMessage,
  recoveryPhaseLabel,
  recoveryStatusMessage
} from './recoveryCopy.js';
import './database.css';
import '../system/system.css';

type DatabaseWorkspaceMode = 'story' | 'atlas' | 'system';

const DATABASE_MODES: { id: DatabaseWorkspaceMode; label: string; glyph: string }[] = [
  { id: 'story', label: 'Story', glyph: '▤' },
  { id: 'atlas', label: 'Atlas', glyph: '◎' },
  { id: 'system', label: 'System', glyph: '⚙' }
];

function DatabaseSkeleton() {
  return (
    <div className="system-skeleton" aria-busy="true">
      <div className="system-skeleton-line" />
    </div>
  );
}

function DatabaseModeSwitcher({
  mode,
  onModeChange
}: {
  mode: DatabaseWorkspaceMode;
  onModeChange: (mode: DatabaseWorkspaceMode) => void;
}) {
  return (
    <div className="system-segmented database-mode-switcher" role="group" aria-label="Database workspace mode">
      {DATABASE_MODES.map((m) => (
        <button
          key={m.id}
          type="button"
          className="system-segmented-item"
          aria-pressed={mode === m.id}
          onClick={() => onModeChange(m.id)}
        >
          <span className="database-mode-glyph" aria-hidden="true">
            {m.glyph}
          </span>
          {m.label}
        </button>
      ))}
    </div>
  );
}

function DatabaseRecordInspector({
  file,
  projectID,
  onClose
}: {
  file: DatabaseWorkspaceFile;
  projectID: string;
  onClose: () => void;
}) {
  return (
    <section className="database-system-band database-record-inspector" aria-labelledby="database-record-inspector-heading">
      <div className="database-record-inspector-header">
        <div>
          <h4 id="database-record-inspector-heading" className="database-system-band-title">
            Record inspector
          </h4>
          <p className="muted">
            Daemon-provided indexed metadata for this record. Source contents are not fetched or inferred by this view.
          </p>
        </div>
        <button type="button" className="ghost" onClick={onClose} aria-label="Close record inspector">
          Close inspector
        </button>
      </div>
      <dl className="fact-grid">
        <div className="fact">
          <dt>Record ID</dt>
          <dd><code className="inline-code">{file.id}</code></dd>
        </div>
        <div className="fact">
          <dt>Path</dt>
          <dd><code className="inline-code">{file.filePath}</code></dd>
        </div>
        <div className="fact">
          <dt>Language</dt>
          <dd>{file.lang}</dd>
        </div>
        <div className="fact">
          <dt>Symbols</dt>
          <dd>{file.symbolCount}</dd>
        </div>
        <div className="fact">
          <dt>Project</dt>
          <dd>{projectID}</dd>
        </div>
      </dl>
    </section>
  );
}

function DatabaseRecoveryBundleControls({
  bridge,
  fixtureMode
}: {
  bridge: ReturnType<typeof useShellStore.getState>['bridge'];
  fixtureMode: boolean;
}) {
  const [exportPath, setExportPath] = useState('');
  const [importPath, setImportPath] = useState('');
  const [exportPassphrase, setExportPassphrase] = useState('');
  const [importPassphrase, setImportPassphrase] = useState('');
  const statusAction = useDatabaseStore((state) => state.recoveryStatusAction);
  const exportAction = useDatabaseStore((state) => state.recoveryExportAction);
  const importAction = useDatabaseStore((state) => state.recoveryImportAction);
  const loadRecoveryStatus = useDatabaseStore((state) => state.loadRecoveryStatus);
  const exportRecoveryBundle = useDatabaseStore((state) => state.exportRecoveryBundle);
  const importRecoveryBundle = useDatabaseStore((state) => state.importRecoveryBundle);
  const pickerAvailable = !fixtureMode && typeof bridge?.pickRecoveryBundleDestination === 'function';
  const exportAvailable = pickerAvailable && typeof bridge?.databaseRecoveryBundleExport === 'function';
  const importAvailable = pickerAvailable && typeof bridge?.databaseRecoveryBundleImport === 'function';
  const available = exportAvailable || importAvailable;
  const recoveryStatus = statusAction.result;
  const busy = exportAction.pending ? 'export' : importAction.pending ? 'import' : null;
  const [pickerBusy, setPickerBusy] = useState<'export' | 'import' | null>(null);
  const [pickerError, setPickerError] = useState<string | null>(null);
  const recoveryBusy = busy !== null || pickerBusy !== null;

  useEffect(() => {
    void loadRecoveryStatus();
  }, [loadRecoveryStatus]);

  const exportBundle = async () => {
    await exportRecoveryBundle(exportPath, exportPassphrase);
    if (!useDatabaseStore.getState().recoveryExportAction.error) setExportPassphrase('');
  };

  const importBundle = async () => {
    await importRecoveryBundle(importPath, importPassphrase);
    if (!useDatabaseStore.getState().recoveryImportAction.error) setImportPassphrase('');
  };

  return (
    <section className="database-system-band" aria-labelledby="database-recovery-heading">
      <h4 id="database-recovery-heading" className="database-system-band-title">
        Encrypted recovery bundle
      </h4>
      <p className="muted">
        Export or restore only the SQLCipher key. The daemon performs PBKDF2/AES-GCM and native secret-store writes;
        this view never persists a passphrase.
      </p>
      {statusAction.pending ? <p className="muted" role="status" aria-live="polite">Checking encrypted-store recovery state...</p> : null}
      {statusAction.error ? <p className="muted" role="alert">{statusAction.error}</p> : null}
      {recoveryStatus ? (
        <div className="database-recovery-status" role="status" aria-live="polite" data-recovery-phase={recoveryStatus.phase}>
          <strong>{`Recovery state: ${recoveryPhaseLabel(recoveryStatus.phase)}`}</strong>
          <p className="muted">{recoveryStatusMessage(recoveryStatus)}</p>
          {recoveryStatus.recommendedAction !== 'none' ? (
            <p className="muted">{`Next action: ${recoveryActionLabel(recoveryStatus.recommendedAction)}`}</p>
          ) : null}
          {recoveryStatus.restartRequired ? <p className="muted">Restart the daemon after the recovery step completes.</p> : null}
          <button
            type="button"
            className="ghost"
            onClick={() => void loadRecoveryStatus()}
            disabled={statusAction.pending || recoveryBusy}
            aria-busy={statusAction.pending}
          >
            {statusAction.pending ? 'Refreshing...' : 'Refresh recovery status'}
          </button>
        </div>
      ) : null}
      {!available ? (
        <p className="muted" role="status">Recovery bundle controls require a packaged Linux daemon with SQLCipher and native secret storage.</p>
      ) : (
        <>
          {pickerError ? <p className="muted" role="alert">{pickerError}</p> : null}
          {exportAvailable ? (
            <div className="actions">
              <div className="setting-field">
                <span>Export destination</span>
                <div className="actions">
                  <button
                    type="button"
                    className="ghost"
                    disabled={recoveryBusy}
                    aria-busy={pickerBusy === 'export'}
                    aria-label="Choose recovery bundle export destination"
                    onClick={() => {
                      if (!bridge?.pickRecoveryBundleDestination || recoveryBusy) return;
                      setPickerBusy('export');
                      setPickerError(null);
                      void bridge.pickRecoveryBundleDestination('export')
                        .then((path) => { if (path) setExportPath(path); })
                        .catch((cause) => setPickerError(cause instanceof Error ? cause.message : 'Could not choose a recovery bundle destination.'))
                        .finally(() => setPickerBusy(null));
                    }}
                  >
                    {pickerBusy === 'export' ? 'Opening...' : 'Choose destination'}
                  </button>
                  {exportPath ? <code>{exportPath}</code> : <span className="muted">No destination selected</span>}
                </div>
              </div>
              <label>
                Export passphrase
                <input
                  type="password"
                  value={exportPassphrase}
                  onChange={(event) => setExportPassphrase(event.target.value)}
                  autoComplete="new-password"
                />
              </label>
              <button
                type="button"
                className="ghost"
                onClick={() => void exportBundle()}
                disabled={recoveryBusy || recoveryStatus?.canExport !== true || exportPath.trim().length === 0 || exportPassphrase.length === 0}
              >
                {busy === 'export' ? 'Exporting...' : 'Export bundle'}
              </button>
            </div>
          ) : (
            <p className="muted" role="status">Recovery export is unavailable in this packaged shell.</p>
          )}
          {importAvailable ? (
            <div className="actions">
              <div className="setting-field">
                <span>Import source</span>
                <div className="actions">
                  <button
                    type="button"
                    className="ghost"
                    disabled={recoveryBusy}
                    aria-busy={pickerBusy === 'import'}
                    aria-label="Choose recovery bundle import source"
                    onClick={() => {
                      if (!bridge?.pickRecoveryBundleDestination || recoveryBusy) return;
                      setPickerBusy('import');
                      setPickerError(null);
                      void bridge.pickRecoveryBundleDestination('import')
                        .then((path) => { if (path) setImportPath(path); })
                        .catch((cause) => setPickerError(cause instanceof Error ? cause.message : 'Could not choose a recovery bundle source.'))
                        .finally(() => setPickerBusy(null));
                    }}
                  >
                    {pickerBusy === 'import' ? 'Opening...' : 'Choose source'}
                  </button>
                  {importPath ? <code>{importPath}</code> : <span className="muted">No source selected</span>}
                </div>
              </div>
              <label>
                Import passphrase
                <input
                  type="password"
                  value={importPassphrase}
                  onChange={(event) => setImportPassphrase(event.target.value)}
                  autoComplete="current-password"
                />
              </label>
              <button
                type="button"
                className="ghost"
                onClick={() => void importBundle()}
                disabled={recoveryBusy || recoveryStatus?.canImport !== true || importPath.trim().length === 0 || importPassphrase.length === 0}
              >
                {busy === 'import' ? 'Importing...' : 'Import bundle'}
              </button>
            </div>
          ) : (
            <p className="muted" role="status">Recovery import is unavailable in this packaged shell.</p>
          )}
          {exportAction.result ? (
            <p className="muted" role="status">
              Recovery bundle exported successfully ({formatBytes(exportAction.result.byteCount)}). The destination path is kept private.
            </p>
          ) : null}
          {importAction.result ? <p className="muted" role="status">{recoveryImportMessage(importAction.result)}</p> : null}
          {exportAction.error ? <p className="muted" role="alert">{exportAction.error}</p> : null}
          {importAction.error ? <p className="muted" role="alert">{importAction.error}</p> : null}
        </>
      )}
    </section>
  );
}

export function DatabaseSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();
  const db = useSystemStore((s) => s.db);
  const loading = useSystemStore((s) => s.loading);
  const error = useSystemStore((s) => s.error);
  const loadDb = useSystemStore((s) => s.loadDb);
  const workspace = useDatabaseStore((s) => s.workspace);
  const workspaceLoading = useDatabaseStore((s) => s.loading);
  const workspaceError = useDatabaseStore((s) => s.error);
  const loadWorkspace = useDatabaseStore((s) => s.loadWorkspace);
  const indexAction = useDatabaseStore((s) => s.indexAction);
  const watchAction = useDatabaseStore((s) => s.watchAction);
  const indexProject = useDatabaseStore((s) => s.indexProject);
  const watchProject = useDatabaseStore((s) => s.watchProject);
  const snapshotAction = useDatabaseStore((s) => s.snapshotAction);
  const restoreAction = useDatabaseStore((s) => s.restoreAction);
  const exportSnapshot = useDatabaseStore((s) => s.exportSnapshot);
  const restoreSnapshot = useDatabaseStore((s) => s.restoreSnapshot);
  const [mode, setMode] = useState<DatabaseWorkspaceMode>('story');
  const [selectedFileID, setSelectedFileID] = useState<string | null>(null);
  const [snapshotPath, setSnapshotPath] = useState('');
  const [restorePath, setRestorePath] = useState('');
  const [snapshotPickerBusy, setSnapshotPickerBusy] = useState(false);
  const [snapshotPickerError, setSnapshotPickerError] = useState<string | null>(null);
  const [snapshotPickerNotice, setSnapshotPickerNotice] = useState<string | null>(null);
  const snapshotExportPickerRef = useRef<HTMLButtonElement>(null);
  const snapshotImportPickerRef = useRef<HTMLButtonElement>(null);
  const snapshotExportAvailable = !fixtureMode
    && typeof bridge?.databaseSnapshot === 'function'
    && typeof bridge?.pickDatabaseSnapshotPath === 'function';
  const snapshotImportAvailable = !fixtureMode
    && typeof bridge?.databaseRestore === 'function'
    && typeof bridge?.pickDatabaseSnapshotPath === 'function';
  const selectedFile = workspace?.files.find((file) => file.id === selectedFileID) ?? null;
  const loadAll = useCallback(async () => {
    await Promise.all([loadDb(), loadWorkspace()]);
  }, [loadDb, loadWorkspace]);

  const chooseSnapshotPath = async (mode: 'export' | 'import') => {
    if (!bridge?.pickDatabaseSnapshotPath || snapshotPickerBusy) return;
    setSnapshotPickerBusy(true);
    setSnapshotPickerError(null);
    setSnapshotPickerNotice(null);
    try {
      const path = await bridge.pickDatabaseSnapshotPath(mode);
      if (path) {
        if (mode === 'export') setSnapshotPath(path);
        else setRestorePath(path);
      } else {
        setSnapshotPickerNotice(
          mode === 'export' ? 'Snapshot destination selection canceled.' : 'Snapshot restore source selection canceled.'
        );
      }
    } catch (cause) {
      setSnapshotPickerError(cause instanceof Error ? cause.message : 'Could not choose a database snapshot path.');
    } finally {
      setSnapshotPickerBusy(false);
      (mode === 'export' ? snapshotExportPickerRef : snapshotImportPickerRef).current?.focus();
    }
  };

  useEffect(() => {
    if (selectedFileID && !workspace?.files.some((file) => file.id === selectedFileID)) {
      setSelectedFileID(null);
    }
  }, [selectedFileID, workspace?.files]);

  useLaneLoad(loadAll);

  if ((loading && !db) || (workspaceLoading && !workspace && mode !== 'story')) {
    return <DatabaseSkeleton />;
  }

  const offline = !fixtureMode && !bridge && !loading;
  if (offline) {
    return (
      <OfflineNotice
        status={status}
        summary="Database health needs the local daemon before SQLCipher and migration facts can load."
        fixtureMode={fixtureMode}
      />
    );
  }

  if (error && !db) {
    return (
      <Banner tone="degraded" role="alert">
        {error}
        <div className="actions">
          <button type="button" className="ghost" onClick={() => void loadAll()}>
            Retry
          </button>
        </div>
      </Banner>
    );
  }

  if (!db) {
    return <p className="muted">No database status returned.</p>;
  }

  const degraded = !db.sqlcipherOk;
  const sourceLabel = fixtureMode ? 'fixture transcript' : 'live daemon db status';
  const workspaceSourceLabel = fixtureMode ? 'fixture transcript' : (workspace?.sourceLabel ?? 'live daemon code-memory RPCs');
  const workspaceDegraded = workspaceError || workspace?.degradedReasons.join(' · ');

  return (
    <>
      <DatabaseModeSwitcher
        mode={mode}
        onModeChange={(nextMode) => {
          setMode(nextMode);
          if (nextMode !== 'atlas') setSelectedFileID(null);
        }}
      />
      {mode === 'story' ? (
        <>
          {degraded ? (
            <Banner tone="degraded" role="alert">
              SQLCipher is not reporting a sealed store. Recall and credentials may be unavailable until the daemon
              unlocks the database.
            </Banner>
          ) : null}
          <p className="muted data-source">{`Data source: ${sourceLabel}`}</p>
          <dl className="fact-grid">
            <div className="fact">
              <dt>SQLCipher</dt>
              <dd>{db.sqlcipherOk ? 'Sealed' : 'Degraded / locked'}</dd>
            </div>
            <div className="fact">
              <dt>Migration version</dt>
              <dd>{db.migrationVersion}</dd>
            </div>
            <div className="fact">
              <dt>Store size</dt>
              <dd>{formatBytes(db.sizeBytes)}</dd>
            </div>
            <div className="fact">
              <dt>WAL mode</dt>
              <dd>{db.walMode ? 'Enabled' : 'Disabled'}</dd>
            </div>
          </dl>
          <table className="table system-migration-table">
            <thead>
              <tr>
                <th>Migration</th>
                <th>Status</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>schema_v{db.migrationVersion}</td>
                <td>{degraded ? 'blocked' : 'applied'}</td>
                <td>
                  {degraded
                    ? 'Database locked or SQLCipher unavailable — migrations cannot advance.'
                    : 'Local encrypted store matches daemon migration head.'}
                </td>
              </tr>
            </tbody>
          </table>
        </>
      ) : null}
      {mode === 'atlas' ? (
        <section className="database-mode-panel" aria-labelledby="database-atlas-heading">
          <h3 id="database-atlas-heading" className="database-mode-heading">
            Indexed corpus
          </h3>
          {workspaceDegraded ? (
            <Banner tone="degraded" role="alert">
              {workspaceDegraded}
            </Banner>
          ) : null}
          <p className="muted database-mode-lede">
            Atlas reads the daemon code-memory corpus through <code className="inline-code">daemon.code.explore</code>{' '}
            and <code className="inline-code">daemon.code.index_status</code>. If the daemon was started without{' '}
            <code className="inline-code">OPENBURNBAR_INDEX_DATABASE_PATH</code>, this panel degrades honestly.
          </p>
          <p className="muted data-source">{`Data source: ${workspaceSourceLabel}`}</p>
          <dl className="fact-grid">
            <div className="fact">
              <dt>Indexed records</dt>
              <dd role="status">{workspace?.artifactCount ?? 0}</dd>
            </div>
            <div className="fact">
              <dt>Symbols</dt>
              <dd>{workspace?.symbolCount ?? 0}</dd>
            </div>
            <div className="fact">
              <dt>Chunks</dt>
              <dd>{workspace?.chunkCount ?? 0}</dd>
            </div>
            <div className="fact">
              <dt>Store size</dt>
              <dd>{formatBytes(workspace?.storageByteCount ?? db.sizeBytes)}</dd>
            </div>
            <div className="fact">
              <dt>Migration head</dt>
              <dd>schema_v{db.migrationVersion}</dd>
            </div>
          </dl>
          <table className="table database-atlas-table">
            <thead>
              <tr>
                <th>Source</th>
                <th>Title</th>
                <th>Provider</th>
                <th>Project</th>
                <th>Updated</th>
                <th>Inspect</th>
              </tr>
            </thead>
            <tbody>
              {(workspace?.files ?? []).length > 0 ? (
                workspace!.files.map((file) => (
                  <tr key={file.id}>
                    <td>{file.lang}</td>
                    <td>{file.filePath}</td>
                    <td>{file.symbolCount} symbols</td>
                    <td>{workspace?.projectID ?? 'unknown'}</td>
                    <td>{workspace?.indexedAt ?? 'not indexed'}</td>
                    <td>
                      <button
                        type="button"
                        className="ghost"
                        aria-pressed={selectedFileID === file.id}
                        aria-label={`Inspect ${file.filePath}`}
                        onClick={() => setSelectedFileID(file.id)}
                      >
                        {selectedFileID === file.id ? 'Selected' : 'Inspect'}
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={6} className="database-atlas-empty">
                    No corpus rows returned by the daemon. Check index status or run indexing from System mode.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
          {selectedFile ? (
            <DatabaseRecordInspector
              file={selectedFile}
              projectID={workspace?.projectID ?? 'unknown'}
              onClose={() => setSelectedFileID(null)}
            />
          ) : null}
          {(workspace?.languages ?? []).length > 0 ? (
            <table className="table database-atlas-table">
              <thead>
                <tr>
                  <th>Language</th>
                  <th>Files</th>
                  <th>Bytes</th>
                </tr>
              </thead>
              <tbody>
                {workspace!.languages.map((lang) => (
                  <tr key={lang.id}>
                    <td>{lang.lang}</td>
                    <td>{lang.fileCount}</td>
                    <td>{formatBytes(lang.byteCount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : null}
          <CodeRetrievalPanel projectPath={workspace?.projectRoot} />
        </section>
      ) : null}
      {mode === 'system' ? (
        <section className="database-mode-panel" aria-labelledby="database-system-heading">
          <h3 id="database-system-heading" className="database-mode-heading">
            Indexing &amp; projection
          </h3>
          {workspaceDegraded ? (
            <Banner tone="degraded" role="alert">
              {workspaceDegraded}
            </Banner>
          ) : null}
          <p className="muted database-mode-lede">
            System mode uses existing daemon code-memory RPCs. Watch mode is poll-only on Linux; Darwin FSEvents nudges
            are not available, so expect roughly 2 second detection latency.
          </p>
          <p className="muted data-source">{`Data source: ${workspaceSourceLabel}`}</p>
          <div className="database-system-bands">
            <section className="database-system-band" aria-labelledby="database-indexing-heading">
              <h4 id="database-indexing-heading" className="database-system-band-title">
                Indexing control
              </h4>
              <p className="muted">
                Run a bounded project index or start the daemon watch loop for the selected project. The Linux watch path
                polls through <code className="inline-code">daemon.code.watch_project</code>.
              </p>
              <div className="actions">
                <button
                  type="button"
                  className="ghost"
                  onClick={() => void indexProject(workspace?.projectRoot)}
                  disabled={indexAction.pending}
                  aria-busy={indexAction.pending}
                >
                  {indexAction.pending ? 'Indexing...' : 'Index project'}
                </button>
                <button
                  type="button"
                  className="ghost"
                  onClick={() => void watchProject(workspace?.projectRoot)}
                  disabled={watchAction.pending}
                  aria-busy={watchAction.pending}
                >
                  {watchAction.pending ? 'Starting watch...' : 'Watch project'}
                </button>
              </div>
              {indexAction.error ? <p className="muted" role="alert">{indexAction.error}</p> : null}
              {watchAction.error ? <p className="muted" role="alert">{watchAction.error}</p> : null}
              {indexAction.result ? (
                <p className="muted" role="status">
                  Indexed {indexAction.result.indexedFiles} files for {indexAction.result.projectID}.
                </p>
              ) : null}
              {watchAction.result ? (
                <p className="muted" role="status">
                  Poll watch active for {watchAction.result.projectID} every {watchAction.result.pollIntervalSeconds ?? 2}s.
                </p>
              ) : null}
              <dl className="fact-grid">
                <div className="fact">
                  <dt>WAL mode</dt>
                  <dd>{db.walMode ? 'Enabled' : 'Disabled'}</dd>
                </div>
                <div className="fact">
                  <dt>SQLCipher</dt>
                  <dd>{db.sqlcipherOk ? 'Sealed' : 'Degraded / locked'}</dd>
                </div>
                <div className="fact">
                  <dt>Parser</dt>
                  <dd>{workspace?.parserAvailable ? 'Available' : 'Unavailable'}</dd>
                </div>
                <div className="fact">
                  <dt>Storage budget</dt>
                  <dd>{workspace?.storageWithinBudget ? 'Within budget' : 'Over budget'}</dd>
                </div>
              </dl>
            </section>
            <section className="database-system-band" aria-labelledby="database-projection-heading">
              <h4 id="database-projection-heading" className="database-system-band-title">
                Projection queue
              </h4>
              <p className="muted" role="status">
                {workspace?.rejectedCount
                  ? `${workspace.rejectedCount} files rejected by code-memory indexing policy.`
                  : 'No rejected files reported by code-memory status.'}
              </p>
            </section>
            <section className="database-system-band" aria-labelledby="database-retrieval-heading">
              <h4 id="database-retrieval-heading" className="database-system-band-title">
                Retrieval health
              </h4>
              <dl className="fact-grid">
                <div className="fact">
                  <dt>Semantic search</dt>
                  <dd>{workspace?.semanticAvailable ? 'Available' : 'Lexical only'}</dd>
                </div>
                <div className="fact">
                  <dt>References</dt>
                  <dd>{workspace?.referenceCount ?? 0}</dd>
                </div>
                <div className="fact">
                  <dt>Call edges</dt>
                  <dd>{workspace?.callEdgeCount ?? 0}</dd>
                </div>
                <div className="fact">
                  <dt>Diagnostics</dt>
                  <dd>{workspace?.diagnostics.length ?? 0}</dd>
                </div>
              </dl>
              {(workspace?.diagnostics ?? []).length > 0 ? (
                <table className="table database-atlas-table">
                  <thead>
                    <tr>
                      <th>File</th>
                      <th>Tool</th>
                      <th>Cached</th>
                    </tr>
                  </thead>
                  <tbody>
                    {workspace!.diagnostics.map((diag) => (
                      <tr key={diag.id}>
                        <td>{diag.filePath}</td>
                        <td>{diag.tool}</td>
                        <td>{diag.cachedAt || 'unknown'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              ) : null}
            </section>
            <section className="database-system-band" aria-labelledby="database-migration-heading">
              <h4 id="database-migration-heading" className="database-system-band-title">
                Store readiness
              </h4>
              <dl className="fact-grid">
                <div className="fact">
                  <dt>Version</dt>
                  <dd>{workspace?.ops ? `schema_v${workspace.ops.schemaVersion}` : `schema_v${db.migrationVersion}`}</dd>
                </div>
                <div className="fact">
                  <dt>Status</dt>
                  <dd>{workspace?.productionReady ? 'production ready' : degraded ? 'blocked' : 'not release-ready'}</dd>
                </div>
                <div className="fact">
                  <dt>Code DB</dt>
                  <dd>{workspace?.ops ? formatBytes(workspace.ops.databaseFileBytes) : 'operator view unavailable'}</dd>
                </div>
                <div className="fact">
                  <dt>Agent memories</dt>
                  <dd>{workspace?.ops?.agentMemoryCount ?? 0}</dd>
                </div>
              </dl>
              {(workspace?.productionReadinessReasons ?? []).length > 0 ? (
                <ul className="system-check-list">
                  {workspace!.productionReadinessReasons.map((reason) => (
                    <li key={reason}>{reason}</li>
                  ))}
                </ul>
              ) : null}
            </section>
            <section className="database-system-band" aria-labelledby="database-recovery-heading">
              <h4 id="database-recovery-heading" className="database-system-band-title">
                Encrypted snapshot &amp; recovery
              </h4>
              <p className="muted">
                Export or restore the daemon-owned SQLCipher code-memory store. Paths must be absolute, owner-only,
                and outside the active database; the daemon refuses plaintext stores and oversized files.
              </p>
              {snapshotExportAvailable ? (
                <>
                  <div className="setting-field">
                    <span>Snapshot destination</span>
                    <div className="actions">
                      <button
                        type="button"
                        className="ghost"
                        ref={snapshotExportPickerRef}
                        disabled={snapshotPickerBusy || snapshotAction.pending}
                        aria-busy={snapshotPickerBusy}
                        aria-label="Choose snapshot export destination"
                        onClick={() => void chooseSnapshotPath('export')}
                      >
                        {snapshotPickerBusy ? 'Opening...' : 'Choose destination'}
                      </button>
                      {snapshotPath ? <code>{snapshotPath}</code> : <span className="muted">No destination selected</span>}
                    </div>
                  </div>
                  <div className="actions">
                    <button
                      type="button"
                      className="ghost"
                      disabled={snapshotAction.pending || snapshotPath.trim().length === 0}
                      aria-busy={snapshotAction.pending}
                      onClick={() => void exportSnapshot(snapshotPath.trim())}
                    >
                      {snapshotAction.pending ? 'Exporting...' : 'Export encrypted snapshot'}
                    </button>
                  </div>
                </>
              ) : (
                <p className="muted" role="status">Encrypted snapshot export requires the packaged native picker.</p>
              )}
              {snapshotPickerNotice ? <p className="muted" role="status" aria-live="polite">{snapshotPickerNotice}</p> : null}
              {snapshotPickerError ? <p className="muted" role="alert">{snapshotPickerError}</p> : null}
              {snapshotAction.error ? <p className="muted" role="alert">{snapshotAction.error}</p> : null}
              {snapshotAction.result ? (
                <p className="muted" role="status">
                  Encrypted snapshot exported successfully ({formatBytes(snapshotAction.result.byteCount)}). The destination path is kept private.
                </p>
              ) : null}
              {snapshotImportAvailable ? (
                <>
                  <div className="setting-field">
                    <span>Snapshot to restore</span>
                    <div className="actions">
                      <button
                        type="button"
                        className="ghost"
                        ref={snapshotImportPickerRef}
                        disabled={snapshotPickerBusy || restoreAction.pending}
                        aria-busy={snapshotPickerBusy}
                        aria-label="Choose snapshot restore source"
                        onClick={() => void chooseSnapshotPath('import')}
                      >
                        {snapshotPickerBusy ? 'Opening...' : 'Choose source'}
                      </button>
                      {restorePath ? <code>{restorePath}</code> : <span className="muted">No source selected</span>}
                    </div>
                  </div>
                  <div className="actions">
                    <button
                      type="button"
                      className="ghost"
                      disabled={restoreAction.pending || restorePath.trim().length === 0}
                      aria-busy={restoreAction.pending}
                      onClick={() => void restoreSnapshot(restorePath.trim())}
                    >
                      {restoreAction.pending ? 'Restoring...' : 'Restore encrypted snapshot'}
                    </button>
                  </div>
                </>
              ) : (
                <p className="muted" role="status">Encrypted snapshot restore requires the packaged native picker.</p>
              )}
              {restoreAction.error ? <p className="muted" role="alert">{restoreAction.error}</p> : null}
              {restoreAction.result ? (
                <p className="muted" role="status">
                  Restored {formatBytes(restoreAction.result.byteCount)} and verified integrity. Index watchers were
                  stopped; re-index the project after recovery.
                </p>
              ) : null}
            </section>
            <DatabaseRecoveryBundleControls bridge={bridge} fixtureMode={fixtureMode} />
          </div>
          <CodeRetrievalPanel projectPath={workspace?.projectRoot} compact />
        </section>
      ) : null}
    </>
  );
}
