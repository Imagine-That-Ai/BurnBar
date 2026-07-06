import { useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
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
  const [mode, setMode] = useState<DatabaseWorkspaceMode>('story');

  useLaneLoad(loadDb);

  if (loading && !db) {
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
          <button type="button" className="ghost" onClick={() => void loadDb()}>
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
          <p className="muted database-mode-lede">
            Atlas on macOS lists indexed conversations with search, filters, and row selection. Linux partial parity:
            corpus rows need <code className="inline-code">workspace snapshot</code> and search RPCs — not exposed on
            the bridge yet.
          </p>
          <dl className="fact-grid">
            <div className="fact">
              <dt>Indexed records</dt>
              <dd role="status">Unavailable until snapshot RPC ships</dd>
            </div>
            <div className="fact">
              <dt>Store size</dt>
              <dd>{formatBytes(db.sizeBytes)}</dd>
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
              <tr>
                <td colSpan={5} className="database-atlas-empty">
                  No indexed corpus rows from the daemon yet. Story mode still reports SQLCipher and migration facts.
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      ) : null}
      {mode === 'system' ? (
        <section className="database-mode-panel" aria-labelledby="database-system-heading">
          <h3 id="database-system-heading" className="database-mode-heading">
            Indexing &amp; projection
          </h3>
          <p className="muted database-mode-lede">
            System mode on macOS shows indexing control, projection queue jobs, retrieval health, audit feed, and sync
            status. Linux shows store mechanics from <code className="inline-code">db_status</code> until workspace
            health RPCs land.
          </p>
          <div className="database-system-bands">
            <section className="database-system-band" aria-labelledby="database-indexing-heading">
              <h4 id="database-indexing-heading" className="database-system-band-title">
                Indexing control
              </h4>
              <p className="muted">
                Conversation indexing toggles and embedding model selection are not wired on Linux. WAL and migration
                state below reflect the encrypted store the daemon reports.
              </p>
              <dl className="fact-grid">
                <div className="fact">
                  <dt>WAL mode</dt>
                  <dd>{db.walMode ? 'Enabled' : 'Disabled'}</dd>
                </div>
                <div className="fact">
                  <dt>SQLCipher</dt>
                  <dd>{db.sqlcipherOk ? 'Sealed' : 'Degraded / locked'}</dd>
                </div>
              </dl>
            </section>
            <section className="database-system-band" aria-labelledby="database-projection-heading">
              <h4 id="database-projection-heading" className="database-system-band-title">
                Projection queue
              </h4>
              <p className="muted" role="status">
                No projection jobs reported — queue depth and active jobs require workspace snapshot RPCs (partial
                parity).
              </p>
            </section>
            <section className="database-system-band" aria-labelledby="database-retrieval-heading">
              <h4 id="database-retrieval-heading" className="database-system-band-title">
                Retrieval health
              </h4>
              <p className="muted" role="status">
                Semantic index rebuild and rerank metrics are not available from the Linux bridge yet.
              </p>
            </section>
            <section className="database-system-band" aria-labelledby="database-migration-heading">
              <h4 id="database-migration-heading" className="database-system-band-title">
                Migration head
              </h4>
              <dl className="fact-grid">
                <div className="fact">
                  <dt>Version</dt>
                  <dd>schema_v{db.migrationVersion}</dd>
                </div>
                <div className="fact">
                  <dt>Status</dt>
                  <dd>{degraded ? 'blocked' : 'applied'}</dd>
                </div>
              </dl>
            </section>
          </div>
        </section>
      ) : null}
    </>
  );
}