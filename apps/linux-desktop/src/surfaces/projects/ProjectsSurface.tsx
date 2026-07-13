import { useMemo, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type {
  ProjectCadence,
  ProjectEntry,
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

function metadataNumber(record: ProjectRecord | undefined, ...keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record?.metadata[key];
    const parsed = typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : Number.NaN;
    if (Number.isFinite(parsed)) return parsed;
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
  onDelete: () => void;
  onReassign: (targetProjectSlug: string) => void;
}) {
  const stats = projectStats(record);
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
          <h2 id="project-detail-title">{record.displayName}</h2>
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
      </dl>
      <p className="muted project-association-note">
        Session associations come from the daemon controller registry. Linux does not infer them from titles or filesystem names.
      </p>
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
  const bridgeReady = useShellStore((s) => s.bridgeReady);
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

  useLaneLoad(loadProjects);

  const canManage = Boolean(bridge && !fixtureMode && bridge.projectGet && bridge.projectUpsert);
  const canDelete = Boolean(bridge && !fixtureMode && bridge.projectDelete);
  const canReassign = Boolean(bridge && !fixtureMode && bridge.projectReassign);
  const selectedEntry = useMemo(
    () => projects?.find((project) => project.projectSlug === selectedSlug || project.id === selectedSlug),
    [projects, selectedSlug]
  );

  const openProject = async (entry: ProjectEntry) => {
    const slug = entry.projectSlug ?? entry.id;
    setSelectedSlug(slug);
    setDetailError(null);
    setLifecycleError(null);
    setEditing(false);
    if (entry.record && !bridge?.projectGet) {
      setDetail(entry.record);
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
      setDetail(result);
      if (!result) setDetailError('The daemon did not return this project. Refresh and try again.');
    } catch (cause) {
      setDetail(null);
      setDetailError(cause instanceof Error ? cause.message : 'Project detail request failed');
    } finally {
      setDetailLoading(false);
    }
  };

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
            <button type="button" className="ghost" onClick={() => setSelectedSlug(null)}>
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
          onBack={() => setSelectedSlug(null)}
          onEdit={() => {
            if (canManage) setEditing(true);
          }}
          canEdit={canManage}
          reassignTargets={reassignTargets}
          canDelete={canDelete}
          canReassign={canReassign}
          lifecycleBusy={lifecycleBusy}
          lifecycleError={lifecycleError}
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
            <ProjectListCard key={project.id} project={project} onOpen={() => void openProject(project)} />
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
