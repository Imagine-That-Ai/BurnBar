import { useCallback, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import { formatBytes } from '../system/systemFormat.js';
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
  const [mode, setMode] = useState<DatabaseWorkspaceMode>('story');
  const loadAll = useCallback(async () => {
    await Promise.all([loadDb(), loadWorkspace()]);
  }, [loadDb, loadWorkspace]);

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
      <DatabaseModeSwitcher mode={mode} onModeChange={setMode} />
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
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={5} className="database-atlas-empty">
                    No corpus rows returned by the daemon. Check index status or run indexing from System mode.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
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
          </div>
        </section>
      ) : null}
    </>
  );
}
