import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import {
  projectRouteHash,
  projectSelectionFromHash
} from '../../routes.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type {
  ProjectCadence,
  ProjectEntry,
  ProjectHistoryEvent,
  ProjectRecord,
  ProjectUpsertInput
} from '../../tauriBridge.js';
import '../system/system.css';

function ProjectsSkeleton() {
  return (
    <div className="system-skeleton" aria-busy="true">
      <div className="system-skeleton-line" />
    </div>
  );
}

type ProjectCardStats = {
  sessionCount: number;
  totalCostUsd: number;
  tokenCount: number;
};

const PROJECT_WORKSPACE_METADATA_KEYS = [
  'workspacePath',
  'workspace_path',
  'projectRoot',
  'project_root',
  'workingDirectory',
  'working_directory'
] as const;

function authoritativeWorkspacePath(record: ProjectRecord | undefined): string | null {
  for (const key of PROJECT_WORKSPACE_METADATA_KEYS) {
    const value = record?.metadata[key];
    if (typeof value === 'string' && value.startsWith('/') && value === value.trim()) return value;
  }
  return null;
}

function metadataNumber(record: ProjectRecord | undefined, ...keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record?.metadata[key];
    const parsed = typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : Number.NaN;
    if (Number.isFinite(parsed)) return parsed;
  }
  return undefined;
}

function metadataText(record: ProjectRecord | undefined, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record?.metadata[key];
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return undefined;
}

function projectStats(record: ProjectRecord | undefined): ProjectCardStats {
  return {
    // These values are emitted by the daemon's controller activity ingestion;
    // absence is explicit rather than inferred from session titles.
    sessionCount: metadataNumber(record, 'session_count_last_7d') ?? 0,
    totalCostUsd: metadataNumber(record, 'total_cost_last_7d') ?? 0,
    tokenCount: metadataNumber(record, 'total_tokens_last_7d') ?? 0
  };
}

function projectStatusLabel(record: ProjectRecord | undefined): string {
  return record?.status?.replaceAll('_', ' ') ?? 'controller';
}

function projectHistoryLabel(eventType: string): string {
  return eventType
    .replaceAll('_', ' ')
    .replace(/\b\w/g, (character) => character.toUpperCase());
}

function projectDraft(record: ProjectRecord | null, entry?: ProjectEntry): ProjectUpsertInput {
  const slug = record?.projectSlug ?? entry?.projectSlug ?? '';
  const displayName = record?.displayName ?? entry?.name ?? '';
  return {
    id: record?.id ?? (slug ? `project-${slug}` : ''),
    projectSlug: slug,
    displayName,
    summary: record?.summary ?? '',
    status: record?.status === 'paused' ? 'paused' : 'healthy',
    preferredCadence: record?.preferredCadence === 'unknown' ? 'weekly' : (record?.preferredCadence ?? 'weekly'),
    aliases: record?.aliases ?? [],
    automationMode: record?.automationMode === 'unknown' ? 'manual' : (record?.automationMode ?? 'manual'),
    reviewModelID: record?.reviewModelID,
    scheduleHourLocal: record?.scheduleHourLocal ?? 9,
    scheduleWeekdayLocal: record?.scheduleWeekdayLocal ?? 2,
    freshness: record?.freshness === 'unknown' ? 'provisional' : (record?.freshness ?? 'provisional'),
    latestDailyReviewAt: record?.latestDailyReviewAt,
    latestWeeklyReviewAt: record?.latestWeeklyReviewAt,
    nextScheduledReviewAt: record?.nextScheduledReviewAt,
    pendingQuestionCount: record?.pendingQuestionCount ?? 0,
    openFollowupCount: record?.openFollowupCount ?? 0,
    activeMissionCount: record?.activeMissionCount ?? 0,
    activeMissionID: record?.activeMissionID,
    needsOperatorAttention: record?.needsOperatorAttention ?? false,
    ingestionSource: record?.ingestionSource === 'unknown' ? 'manual' : (record?.ingestionSource ?? 'manual'),
    metadata: record?.metadata ?? {}
  };
}

function ProjectEditor({
  initial,
  busy,
  error,
  onCancel,
  onSave
}: {
  initial: ProjectUpsertInput;
  busy: boolean;
  error: string | null;
  onCancel: () => void;
  onSave: (project: ProjectUpsertInput) => void;
}) {
  const [draft, setDraft] = useState<ProjectUpsertInput>(initial);
  const [aliasesText, setAliasesText] = useState(initial.aliases.join(', '));
  const canSave = draft.projectSlug.trim().length > 0 && draft.displayName.trim().length > 0 && !busy;
  const patch = (changes: Partial<ProjectUpsertInput>) => setDraft((current) => ({ ...current, ...changes }));

  return (
    <form
      className="project-detail-panel project-editor"
      onSubmit={(event) => {
        event.preventDefault();
        if (!canSave) return;
        onSave({
          ...draft,
          id: draft.id || `project-${draft.projectSlug.trim()}`,
          projectSlug: draft.projectSlug.trim(),
          displayName: draft.displayName.trim(),
          summary: draft.summary.trim(),
          aliases: aliasesText
            .split(',')
            .map((alias) => alias.trim())
            .filter(Boolean)
        });
      }}
    >
      <div className="project-detail-heading">
        <div>
          <p className="eyebrow">Controller registry</p>
          <h2>{draft.id ? 'Edit project' : 'Register project'}</h2>
        </div>
        <div className="actions">
          <button type="button" className="ghost" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
          <button type="submit" className="primary" disabled={!canSave} aria-busy={busy}>
            {busy ? 'Saving...' : 'Save project'}
          </button>
        </div>
      </div>
      {error ? <p className="project-inline-error" role="alert">{error}</p> : null}
      <div className="project-editor-grid">
        <label>
          <span>Display name</span>
          <input
            value={draft.displayName}
            onChange={(event) => patch({ displayName: event.target.value })}
            autoComplete="off"
          />
        </label>
        <label>
          <span>Project slug</span>
          <input
            value={draft.projectSlug}
            onChange={(event) => patch({ projectSlug: event.target.value })}
            autoComplete="off"
            spellCheck={false}
          />
        </label>
        <label className="project-editor-wide">
          <span>Summary</span>
          <textarea value={draft.summary} onChange={(event) => patch({ summary: event.target.value })} rows={3} />
        </label>
        <label className="project-editor-wide">
          <span>Aliases (comma separated)</span>
          <input value={aliasesText} onChange={(event) => setAliasesText(event.target.value)} autoComplete="off" />
        </label>
        <label>
          <span>Review cadence</span>
          <select
            value={draft.preferredCadence}
            onChange={(event) => patch({ preferredCadence: event.target.value as ProjectCadence })}
          >
            <option value="daily">Daily</option>
            <option value="weekly">Weekly</option>
            <option value="ad_hoc">Ad hoc</option>
          </select>
        </label>
        <label>
          <span>Automation</span>
          <select value={draft.automationMode} onChange={(event) => patch({ automationMode: event.target.value as ProjectUpsertInput['automationMode'] })}>
            <option value="manual">Manual</option>
            <option value="suggested">Suggested</option>
            <option value="scheduled">Scheduled</option>
          </select>
        </label>
        <label>
          <span>Review model ID</span>
          <input
            value={draft.reviewModelID ?? ''}
            onChange={(event) => patch({ reviewModelID: event.target.value || undefined })}
            autoComplete="off"
            spellCheck={false}
          />
        </label>
        <label>
          <span>Local review hour</span>
          <input
            type="number"
            min={0}
            max={23}
            value={draft.scheduleHourLocal ?? 9}
            onChange={(event) => patch({ scheduleHourLocal: Number(event.target.value) })}
          />
        </label>
        <label>
          <span>Local weekday (1-7)</span>
          <input
            type="number"
            min={1}
            max={7}
            value={draft.scheduleWeekdayLocal ?? 2}
            onChange={(event) => patch({ scheduleWeekdayLocal: Number(event.target.value) })}
          />
        </label>
        <label className="project-editor-check">
          <input
            type="checkbox"
            checked={draft.status === 'paused'}
            onChange={(event) => patch({ status: event.target.checked ? 'paused' : 'healthy' })}
          />
          <span>Pause this project</span>
        </label>
      </div>
    </form>
  );
}

function ProjectDetail({
  record,
  onBack,
  onEdit,
  canEdit,
  reassignTargets,
  canDelete,
  canReassign,
  lifecycleBusy,
  lifecycleError,
  history,
  historyLoading,
  historyError,
  onDelete,
  onReassign
}: {
  record: ProjectRecord;
  onBack: () => void;
  onEdit: () => void;
  canEdit: boolean;
  reassignTargets: ProjectRecord[];
  canDelete: boolean;
  canReassign: boolean;
  lifecycleBusy: boolean;
  lifecycleError: string | null;
  history: ProjectHistoryEvent[] | null;
  historyLoading: boolean;
  historyError: string | null;
  onDelete: () => void;
  onReassign: (targetProjectSlug: string) => void;
}) {
  const stats = projectStats(record);
  const latestSessionID = metadataText(record, 'latest_conversation_session_id');
  const [targetProjectSlug, setTargetProjectSlug] = useState('');

  const confirmDelete = () => {
    if (window.confirm(`Delete project "${record.displayName}"? Project history will remain available for reassignment.`)) {
      onDelete();
    }
  };

  const confirmReassign = () => {
    if (!targetProjectSlug) return;
    const target = reassignTargets.find((candidate) => candidate.projectSlug === targetProjectSlug);
    if (!target) return;
    if (window.confirm(`Reassign all durable references from "${record.displayName}" to "${target.displayName}"?`)) {
      onReassign(target.projectSlug);
    }
  };

  return (
    <section className="project-detail-panel" aria-labelledby="project-detail-title">
      <div className="project-detail-heading">
        <div>
          <button type="button" className="ghost project-back-button" onClick={onBack}>
            Back to projects
          </button>
          <p className="eyebrow">Registered project</p>
          <h2 id="project-detail-title" tabIndex={-1}>{record.displayName}</h2>
          <p className="mono project-detail-slug">{record.projectSlug}</p>
        </div>
        <button type="button" className="primary" onClick={onEdit} disabled={!canEdit || lifecycleBusy}>
          Edit project
        </button>
      </div>
      {lifecycleError ? <p className="project-inline-error" role="alert">{lifecycleError}</p> : null}
      <p className="project-detail-summary">{record.summary || 'No project summary has been recorded.'}</p>
      <dl className="project-detail-facts">
        <div><dt>Status</dt><dd>{projectStatusLabel(record)}</dd></div>
        <div><dt>Freshness</dt><dd>{record.freshness.replaceAll('_', ' ')}</dd></div>
        <div><dt>Cadence</dt><dd>{record.preferredCadence.replace('_', ' ')}</dd></div>
        <div><dt>Automation</dt><dd>{record.automationMode}</dd></div>
        <div><dt>Questions</dt><dd>{record.pendingQuestionCount}</dd></div>
        <div><dt>Follow-ups</dt><dd>{record.openFollowupCount}</dd></div>
        <div><dt>Active missions</dt><dd>{record.activeMissionCount}</dd></div>
        <div><dt>Sessions (7d)</dt><dd>{stats.sessionCount || 'No indexed association'}</dd></div>
        <div><dt>Latest session</dt><dd className="mono">{latestSessionID ?? 'No exact session recorded'}</dd></div>
      </dl>
      <p className="muted project-association-note">
        Session associations come from the daemon controller registry. Linux does not infer them from titles or filesystem names.
      </p>
      <section className="project-history" aria-labelledby="project-history-title">
        <div className="project-history-heading">
          <div>
            <p className="eyebrow">Daemon event stream</p>
            <h3 id="project-history-title">Project history</h3>
          </div>
          <span className="muted">Recent events only</span>
        </div>
        {historyLoading ? <p className="muted" role="status">Loading project history...</p> : null}
        {historyError ? <p className="project-inline-error" role="status">{historyError}</p> : null}
        {!historyLoading && !historyError && history && history.length === 0 ? (
          <p className="muted">No controller events have been recorded for this project.</p>
        ) : null}
        {!historyLoading && !historyError && history && history.length > 0 ? (
          <ol className="project-history-list">
            {history.map((event) => (
              <li key={event.id} className="project-history-item">
                <div className="project-history-item-heading">
                  <strong>{projectHistoryLabel(event.eventType)}</strong>
                  <time dateTime={event.recordedAt}>{event.recordedAt}</time>
                </div>
                <span>{event.summary}</span>
                {event.detail ? <small>{event.detail}</small> : null}
                {event.isReplay ? <small className="muted">Recovered from daemon journal replay</small> : null}
              </li>
            ))}
          </ol>
        ) : null}
      </section>
      {record.aliases.length > 0 ? (
        <div className="project-detail-aliases">
          <strong>Aliases</strong>
          <span>{record.aliases.join(', ')}</span>
        </div>
      ) : null}
      {canReassign && reassignTargets.length > 0 ? (
        <div className="project-lifecycle-actions">
          <label>
            <span>Reassign references to</span>
            <select
              aria-label="Reassign references to"
              value={targetProjectSlug}
              onChange={(event) => setTargetProjectSlug(event.target.value)}
              disabled={lifecycleBusy}
            >
              <option value="">Select a target project</option>
              {reassignTargets.map((target) => (
                <option key={target.projectSlug} value={target.projectSlug}>{target.displayName}</option>
              ))}
            </select>
          </label>
          <button type="button" className="ghost" onClick={confirmReassign} disabled={!targetProjectSlug || lifecycleBusy}>
            {lifecycleBusy ? 'Updating...' : 'Reassign references'}
          </button>
        </div>
      ) : null}
      {canDelete ? (
        <div className="project-lifecycle-actions project-lifecycle-danger">
          <button type="button" className="ghost" onClick={confirmDelete} disabled={lifecycleBusy}>
            {lifecycleBusy ? 'Deleting...' : 'Delete project'}
          </button>
        </div>
      ) : null}
    </section>
  );
}

function ProjectListCard({
  project,
  onOpen
}: {
  project: ProjectEntry;
  onOpen: () => void;
}) {
  const stats = projectStats(project.record);
  const record = project.record;
  return (
    <article className="project-list-card">
      <header className="project-list-card-header">
        <h3 className="project-list-card-title">{project.name}</h3>
        <span className="system-scope-chip" data-scope={project.scope}>
          {record ? projectStatusLabel(record) : project.scope}
        </span>
      </header>
      <p className="project-list-card-path mono">{record?.projectSlug ?? project.id}</p>
      <p className="project-list-card-summary">{record?.summary || 'Controller-managed project registry entry.'}</p>
      <div className="project-list-card-metrics">
        {stats.sessionCount > 0 ? (
          <>
            <span className="project-list-card-cost">{stats.sessionCount} sessions</span>
            <span className="muted project-list-card-sessions">{stats.tokenCount.toLocaleString()} tokens / ${stats.totalCostUsd.toFixed(2)} / 7d</span>
          </>
        ) : (
          <span className="muted project-list-card-sessions">No indexed associations</span>
        )}
      </div>
      <div className="actions project-list-card-actions">
        {record ? (
          <button type="button" className="ghost" onClick={onOpen}>
            Open details
          </button>
        ) : (
          <span className="muted">Detail unavailable from this source</span>
        )}
      </div>
    </article>
  );
}

export function ProjectsSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const routeHash = useShellStore((s) => s.routeHash);
  const routeRevision = useShellStore((s) => s.routeRevision);
  const navigateDestination = useShellStore((s) => s.navigateDestination);
  const setRoute = useShellStore((s) => s.setRoute);
  const status = useDaemonStatusCopy();
  const projects = useSystemStore((s) => s.projects);
  const loading = useSystemStore((s) => s.loading);
  const error = useSystemStore((s) => s.error);
  const loadProjects = useSystemStore((s) => s.loadProjects);
  const [selectedSlug, setSelectedSlug] = useState<string | null>(null);
  const [detail, setDetail] = useState<ProjectRecord | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [lifecycleBusy, setLifecycleBusy] = useState(false);
  const [lifecycleError, setLifecycleError] = useState<string | null>(null);
  const [history, setHistory] = useState<ProjectHistoryEvent[] | null>(null);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const historyRequestRef = useRef(0);
  const routedRequestRef = useRef<string | null>(null);

  useLaneLoad(loadProjects);

  const canManage = Boolean(bridge && !fixtureMode && bridge.projectGet && bridge.projectUpsert);
  const canDelete = Boolean(bridge && !fixtureMode && bridge.projectDelete);
  const canReassign = Boolean(bridge && !fixtureMode && bridge.projectReassign);
  const selectedEntry = useMemo(
    () => projects?.find((project) => project.projectSlug === selectedSlug || project.id === selectedSlug),
    [projects, selectedSlug]
  );

  const openProject = useCallback(async (entry: ProjectEntry) => {
    const slug = entry.projectSlug ?? entry.id;
    const requestID = historyRequestRef.current + 1;
    historyRequestRef.current = requestID;
    setSelectedSlug(slug);
    setDetailError(null);
    setLifecycleError(null);
    setHistory(null);
    setHistoryError(null);
    setEditing(false);
    if (!bridge?.projectHistory) {
      setHistoryError('Project history is unavailable from this packaged daemon.');
    }
    if (entry.record && !bridge?.projectGet) {
      if (historyRequestRef.current === requestID) setDetail(entry.record);
      if (bridge?.projectHistory) {
        setHistoryLoading(true);
        try {
          const result = await bridge.projectHistory(slug);
          if (historyRequestRef.current === requestID) setHistory(result);
        } catch (cause) {
          if (historyRequestRef.current === requestID) {
            setHistoryError(cause instanceof Error ? cause.message : 'Project history is unavailable');
          }
        } finally {
          if (historyRequestRef.current === requestID) setHistoryLoading(false);
        }
      }
      return;
    }
    if (!bridge?.projectGet) {
      setDetail(null);
      setDetailError('Project detail requires the packaged daemon controller bridge.');
      return;
    }
    setDetailLoading(true);
    try {
      const result = await bridge.projectGet(slug);
      if (historyRequestRef.current !== requestID) return;
      setDetail(result);
      if (!result) setDetailError('The daemon did not return this project. Refresh and try again.');
      if (result && bridge.projectHistory) {
        setHistoryLoading(true);
        try {
          const projectHistory = await bridge.projectHistory(slug);
          if (historyRequestRef.current === requestID) setHistory(projectHistory);
        } catch (cause) {
          if (historyRequestRef.current === requestID) {
            setHistoryError(cause instanceof Error ? cause.message : 'Project history is unavailable');
          }
        } finally {
          if (historyRequestRef.current === requestID) setHistoryLoading(false);
        }
      }
    } catch (cause) {
      if (historyRequestRef.current !== requestID) return;
      setDetail(null);
      setDetailError(cause instanceof Error ? cause.message : 'Project detail request failed');
    } finally {
      if (historyRequestRef.current === requestID) setDetailLoading(false);
    }
  }, [bridge]);

  useEffect(() => {
    const selection = projectSelectionFromHash(routeHash);
    if (!selection) {
      if (routedRequestRef.current !== null) {
        routedRequestRef.current = null;
        historyRequestRef.current += 1;
        setSelectedSlug(null);
        setDetail(null);
        setDetailError(null);
        setDetailLoading(false);
        setEditing(false);
      }
      return;
    }

    const requestKey = `${routeRevision}:${routeHash}`;
    if (routedRequestRef.current === requestKey) return;

    if (selection.kind === 'workspace') {
      if (projects === null) return;
      const matches = projects.filter(
        (entry) => authoritativeWorkspacePath(entry.record) === selection.workspacePath
      );
      routedRequestRef.current = requestKey;
      if (matches.length !== 1) {
        historyRequestRef.current += 1;
        setSelectedSlug(selection.workspacePath);
        setDetail(null);
        setDetailLoading(false);
        setEditing(false);
        setDetailError(
          matches.length > 1
            ? 'More than one registered project claims this exact workspace path. Resolve the controller registry conflict and retry.'
            : 'This exact workspace is no longer registered with a canonical controller project.'
        );
        return;
      }
      void openProject(matches[0]!);
      return;
    }

    if (projects === null && !bridge?.projectGet) return;
    routedRequestRef.current = requestKey;
    const exact = projects?.find(
      (entry) => entry.id === selection.projectID || entry.projectSlug === selection.projectID
    );
    void openProject(
      exact ?? {
        id: selection.projectID,
        name: selection.projectID,
        path: '',
        scope: 'controller',
        projectSlug: selection.projectID
      }
    );
  }, [bridge, openProject, projects, routeHash, routeRevision]);

  useEffect(() => {
    if (!detail || !projectSelectionFromHash(routeHash)) return;
    const frame = window.requestAnimationFrame(() => {
      const heading = document.getElementById('project-detail-title');
      heading?.scrollIntoView?.({ block: 'nearest' });
      heading?.focus?.({ preventScroll: true });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [detail, routeHash, routeRevision]);

  const deleteProject = async () => {
    if (!bridge?.projectDelete || !detail) return;
    setLifecycleBusy(true);
    setLifecycleError(null);
    try {
      const result = await bridge.projectDelete(detail.projectSlug);
      if (!result.deleted) throw new Error('The daemon did not confirm project deletion.');
      await loadProjects();
      setDetail(null);
      setSelectedSlug(null);
    } catch (cause) {
      setLifecycleError(cause instanceof Error ? cause.message : 'Project deletion failed');
    } finally {
      setLifecycleBusy(false);
    }
  };

  const reassignProject = async (targetProjectSlug: string) => {
    if (!bridge?.projectReassign || !detail) return;
    setLifecycleBusy(true);
    setLifecycleError(null);
    try {
      await bridge.projectReassign(detail.projectSlug, targetProjectSlug);
      await loadProjects();
    } catch (cause) {
      setLifecycleError(cause instanceof Error ? cause.message : 'Project reassignment failed');
    } finally {
      setLifecycleBusy(false);
    }
  };

  const saveProject = async (project: ProjectUpsertInput) => {
    if (!bridge?.projectUpsert) return;
    setSaving(true);
    setDetailError(null);
    try {
      const saved = await bridge.projectUpsert(project);
      if (!saved) throw new Error('The daemon did not return the saved project.');
      setDetail(saved);
      setSelectedSlug(saved.projectSlug);
      setEditing(false);
      await loadProjects();
    } catch (cause) {
      setDetailError(cause instanceof Error ? cause.message : 'Project save failed');
    } finally {
      setSaving(false);
    }
  };

  if (loading && projects === null) {
    return <ProjectsSkeleton />;
  }

  const offline = !fixtureMode && !bridge && !loading;
  if (offline) {
    return (
      <OfflineNotice
        status={status}
        summary="Projects need the local daemon before the controller registry can load."
        fixtureMode={fixtureMode}
      />
    );
  }

  if (error && projects === null) {
    return (
      <Banner tone="degraded" role="alert">
        {error}
        <div className="actions">
          <button type="button" className="ghost" onClick={() => void loadProjects()}>
            Retry
          </button>
        </div>
      </Banner>
    );
  }

  const list = projects ?? [];
  const sourceLabel = fixtureMode ? 'fixture transcript' : 'live daemon controller registry';

  if (selectedSlug) {
    if (selectedSlug === '__new__' && editing) {
      return (
        <ProjectEditor
          initial={projectDraft(null)}
          busy={saving}
          error={detailError}
          onCancel={() => {
            setEditing(false);
            setSelectedSlug(null);
          }}
          onSave={(project) => void saveProject(project)}
        />
      );
    }
    if (detailLoading) return <ProjectsSkeleton />;
    if (detailError && !detail) {
      return (
        <Banner tone="degraded" role="alert">
          {detailError}
          <div className="actions">
            <button type="button" className="ghost" onClick={() => setRoute('projects')}>
              Back to projects
            </button>
          </div>
        </Banner>
      );
    }
    if (detail && editing) {
      return (
        <ProjectEditor
          initial={projectDraft(detail, selectedEntry)}
          busy={saving}
          error={detailError}
          onCancel={() => setEditing(false)}
          onSave={(project) => void saveProject(project)}
        />
      );
    }
    if (detail) {
      const reassignTargets = list
        .map((entry) => entry.record)
        .filter((candidate): candidate is ProjectRecord => Boolean(candidate && candidate.projectSlug !== detail.projectSlug));
      return (
        <ProjectDetail
          record={detail}
          onBack={() => setRoute('projects')}
          onEdit={() => {
            if (canManage) setEditing(true);
          }}
          canEdit={canManage}
          reassignTargets={reassignTargets}
          canDelete={canDelete}
          canReassign={canReassign}
          lifecycleBusy={lifecycleBusy}
          lifecycleError={lifecycleError}
          history={history}
          historyLoading={historyLoading}
          historyError={historyError}
          onDelete={() => void deleteProject()}
          onReassign={(targetProjectSlug) => void reassignProject(targetProjectSlug)}
        />
      );
    }
  }

  return (
    <>
      <div className="project-list-toolbar">
        <p className="muted data-source">{`Data source: ${sourceLabel}`}</p>
        {canManage ? (
          <button
            type="button"
            className="primary"
            onClick={() => {
              setDetail(null);
              setDetailError(null);
              setSelectedSlug('__new__');
              setEditing(true);
            }}
          >
            Register project
          </button>
        ) : null}
      </div>
      {list.length === 0 ? (
        <p className="muted">No projects registered</p>
      ) : (
        <div className="project-list-grid">
          {list.map((project) => (
            <ProjectListCard
              key={project.id}
              project={project}
              onOpen={() => navigateDestination({
                route: 'projects',
                hash: projectRouteHash(project.projectSlug ?? project.id)
              })}
            />
          ))}
        </div>
      )}
      {!canManage && !fixtureMode ? (
        <p className="muted project-capability-note">
          Project editing is unavailable until the packaged daemon exposes the canonical controller bridge.
        </p>
      ) : null}
    </>
  );
}
