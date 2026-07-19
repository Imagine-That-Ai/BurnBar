import { useEffect, useState } from 'react';
import { SettingRow } from './SettingRow.js';
import {
  DECK_TIME_RANGES,
  persistDeckHeroUnit,
  persistDeckTimeRange,
  readDeckHeroUnit,
  readDeckTimeRange,
  type DeckHeroUnit,
  type DeckTimeRange
} from '../../components/deckPrimaryRoutes.js';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useShellStore } from '../../state/shellStore.js';

/**
 * macOS General → Dashboard Defaults, backed by the same persisted contract
 * consumed by the Overview BURN hero. These preferences are local display
 * choices, so they must remain usable without inventing a daemon RPC.
 */
export function DashboardDefaultsControls() {
  const [range, setRange] = useState<DeckTimeRange>(() => readDeckTimeRange());
  const [unit, setUnit] = useState<DeckHeroUnit>(() => readDeckHeroUnit());

  return (
    <>
      <SettingRow
        iconGlyph="◷"
        label="Default time range"
        description="The window used by the Overview BURN total when the dashboard opens."
        control={
          <select
            value={range}
            aria-label="Default dashboard time range"
            onChange={(event) => {
              const next = event.currentTarget.value as DeckTimeRange;
              setRange(next);
              persistDeckTimeRange(next);
            }}
          >
            {DECK_TIME_RANGES.map((option) => (
              <option key={option.id} value={option.id}>{option.label}</option>
            ))}
          </select>
        }
      />
      <SettingRow
        iconGlyph="¤"
        label="Usage display"
        description="Show estimated USD cost or token volume in the Overview BURN total."
        control={
          <select
            value={unit}
            aria-label="Default dashboard usage display"
            onChange={(event) => {
              const next = event.currentTarget.value as DeckHeroUnit;
              setUnit(next);
              persistDeckHeroUnit(next);
            }}
          >
            <option value="cost">USD</option>
            <option value="tokens">Tokens</option>
          </select>
        }
      />
    </>
  );
}

function indexingSummary(
  workspace: ReturnType<typeof useDatabaseStore.getState>['workspace']
): { status: string; statusTone: 'ok' | 'warn'; detail: string } {
  if (!workspace) {
    return { status: 'Unavailable', statusTone: 'warn', detail: 'No index status returned.' };
  }
  if (workspace.degradedReasons.length > 0) {
    return {
      status: 'Degraded',
      statusTone: 'warn',
      detail: workspace.degradedReasons[0]!
    };
  }
  const mode = workspace.semanticAvailable ? 'semantic' : 'lexical';
  return {
    status: workspace.productionReady ? 'Ready' : 'Available',
    statusTone: workspace.productionReady ? 'ok' : 'warn',
    detail: `${workspace.artifactCount.toLocaleString()} records · ${mode} search`
  };
}

/**
 * Read-only indexing posture for General Settings. Index mutations remain in
 * the Database surface, where the existing daemon RPCs and project scope are
 * explicit. This row never claims an on/off setting that Linux cannot save.
 */
export function IndexingSummaryControl({ onOpenDatabase }: { onOpenDatabase: () => void }) {
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridge = useShellStore((state) => state.bridge);
  const workspace = useDatabaseStore((state) => state.workspace);
  const loading = useDatabaseStore((state) => state.loading);
  const error = useDatabaseStore((state) => state.error);
  const loadWorkspace = useDatabaseStore((state) => state.loadWorkspace);
  const supported = fixtureMode || typeof bridge?.databaseWorkspaceStatus === 'function';

  useEffect(() => {
    if (supported) void loadWorkspace();
  }, [loadWorkspace, supported]);

  if (!supported) {
    return (
      <SettingRow
        iconGlyph="⌕"
        label="Indexing & Search"
        description="Inspect local code-memory indexing and retrieval posture."
        control={<span className="muted" role="status" aria-label="Unavailable">Unavailable</span>}
        readOnlyNote="The packaged daemon does not expose the index-status RPC; no indexing claim is made here."
      />
    );
  }

  const posture = indexingSummary(workspace);
  const detail = error && !workspace ? error : posture.detail;

  return (
    <SettingRow
      iconGlyph="⌕"
      label="Indexing & Search"
      description="Daemon-owned local index status. Use Database for project indexing, watch, and retrieval controls."
      control={
        <span className="settings-verification-value">
          <span
            className={`status-pill ${posture.statusTone}`}
            role="status"
            aria-label={loading && !workspace ? 'Loading' : posture.status}
            title={detail}
          >
            {loading && !workspace ? 'Loading…' : posture.status}
          </span>
          <button type="button" className="ghost" onClick={onOpenDatabase}>Open Database</button>
        </span>
      }
      readOnlyNote={detail}
    />
  );
}
