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
import type { LinuxLaunchAtLoginStatus } from '../../tauriBridge.js';

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

/**
 * Linux-native equivalent of macOS General → Launch at Login. The native
 * bridge owns the XDG path and writes a user override from the packaged
 * desktop-entry template; the renderer receives only the boolean preference.
 */
export function LaunchAtLoginControl() {
  const bridge = useShellStore((state) => state.bridge);
  const readStatus = bridge?.launchAtLoginStatus;
  const setStatus = bridge?.launchAtLoginSet;
  const supported = typeof readStatus === 'function' && typeof setStatus === 'function';
  const [status, setStatusValue] = useState<LinuxLaunchAtLoginStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (!readStatus) {
      setStatusValue(null);
      return () => {
        cancelled = true;
      };
    }
    setError(null);
    void readStatus()
      .then((next) => {
        if (!cancelled) setStatusValue(next);
      })
      .catch((reason: unknown) => {
        if (!cancelled) setError(reason instanceof Error ? reason.message : String(reason));
      });
    return () => {
      cancelled = true;
    };
  }, [readStatus]);

  if (!supported) {
    return (
      <SettingRow
        iconGlyph="⇥"
        label="Launch at login"
        description="Start OpenBurnBar in the background when your Linux desktop session begins."
        control={<span className="muted" role="status" aria-label="Unavailable">Unavailable</span>}
        readOnlyNote="This packaged shell does not expose the safe XDG autostart preference."
      />
    );
  }

  const toggle = async (enabled: boolean) => {
    if (!setStatus) return;
    setBusy(true);
    setError(null);
    try {
      setStatusValue(await setStatus(enabled));
    } catch (reason: unknown) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setBusy(false);
    }
  };

  const statusText = status
    ? status.enabled
      ? 'Enabled'
      : 'Disabled'
    : busy
      ? 'Saving…'
      : 'Loading…';

  return (
    <SettingRow
      iconGlyph="⇥"
      label="Launch at login"
      description="Start OpenBurnBar in the background when your Linux desktop session begins."
      control={
        <label className="setting-toggle">
          <input
            type="checkbox"
            checked={status?.enabled ?? false}
            disabled={busy || !status}
            aria-busy={busy || !status}
            aria-label="Launch OpenBurnBar at login"
            onChange={(event) => void toggle(event.currentTarget.checked)}
          />
          <span className="muted" role="status" aria-live="polite" aria-label={statusText}>{statusText}</span>
        </label>
      }
      readOnlyNote={error ?? status?.detail}
    />
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
 * Daemon-backed indexing posture for General Settings. The summary stays
 * compact, while the bounded project-index action uses the same typed store
 * contract as the Database surface and keeps project scope daemon-owned.
 */
export function IndexingSummaryControl({ onOpenDatabase }: { onOpenDatabase: () => void }) {
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridge = useShellStore((state) => state.bridge);
  const workspace = useDatabaseStore((state) => state.workspace);
  const loading = useDatabaseStore((state) => state.loading);
  const error = useDatabaseStore((state) => state.error);
  const indexAction = useDatabaseStore((state) => state.indexAction);
  const loadWorkspace = useDatabaseStore((state) => state.loadWorkspace);
  const indexProject = useDatabaseStore((state) => state.indexProject);
  const supported = fixtureMode || typeof bridge?.databaseWorkspaceStatus === 'function';
  const indexingSupported = fixtureMode || typeof bridge?.databaseIndexProject === 'function';

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
  const indexResult = indexAction.result;
  const indexStatus = indexAction.error
    ? indexAction.error
    : indexResult
      ? `Indexed ${indexResult.indexedFiles.toLocaleString()} files for ${indexResult.projectID}.`
      : detail;

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
          {indexingSupported ? (
            <button
              type="button"
              className="ghost"
              onClick={() => void indexProject(workspace?.projectRoot)}
              disabled={indexAction.pending || loading || !workspace?.projectRoot}
              aria-busy={indexAction.pending}
            >
              {indexAction.pending ? 'Indexing…' : 'Index project'}
            </button>
          ) : null}
          <button type="button" className="ghost" onClick={onOpenDatabase}>Open Database</button>
        </span>
      }
      readOnlyNote={indexStatus}
    />
  );
}
