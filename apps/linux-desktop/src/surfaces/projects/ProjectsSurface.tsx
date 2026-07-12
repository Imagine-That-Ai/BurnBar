import { useEffect, useMemo } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { PROVIDER_GLYPHS } from '../../providerGlyphs.js';
import { useActivityStore } from '../../state/activityStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type { ProjectEntry } from '../../tauriBridge.js';
import { formatCostUsd } from '../activity/sessionFormat.js';
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
  providers: string[];
};

function normalizeProjectKey(value: string): string {
  return value.trim().toLowerCase();
}

function projectMatchesSession(project: ProjectEntry, sessionTitle: string): boolean {
  const title = normalizeProjectKey(sessionTitle);
  const id = normalizeProjectKey(project.id);
  const name = normalizeProjectKey(project.name);
  const pathTail = normalizeProjectKey(project.path.split('/').pop() ?? '');
  return title === id || title === name || (pathTail.length > 0 && title.includes(pathTail));
}

function providerAccent(providerId: string): string {
  const glyph = PROVIDER_GLYPHS.find((g) => g.id === providerId);
  return glyph?.accent ?? 'var(--color-brass-core)';
}

function ProjectListCard({
  project,
  stats
}: {
  project: ProjectEntry;
  stats: ProjectCardStats;
}) {
  return (
    <article className="project-list-card">
      <header className="project-list-card-header">
        <h3 className="project-list-card-title">{project.name}</h3>
        <span className="system-scope-chip" data-scope={project.scope}>
          {project.scope}
        </span>
      </header>
      <p className="project-list-card-path mono">{project.path}</p>
      <div className="project-list-card-metrics">
        {stats.sessionCount > 0 ? (
          <>
            <span className="project-list-card-cost">{formatCostUsd(stats.totalCostUsd)}</span>
            <span className="muted project-list-card-sessions">
              {stats.sessionCount} session{stats.sessionCount === 1 ? '' : 's'}
            </span>
          </>
        ) : (
          <span className="muted project-list-card-sessions">No indexed sessions yet</span>
        )}
      </div>
      {stats.providers.length > 0 ? (
        <div className="project-list-card-providers" aria-label="Providers with sessions in this project">
          {stats.providers.slice(0, 4).map((id) => {
            const label = PROVIDER_GLYPHS.find((g) => g.id === id)?.label ?? id;
            return (
              <span
                key={id}
                className="project-list-card-provider"
                title={label}
                style={{ color: providerAccent(id) }}
              >
                <span className="project-list-card-provider-dot" style={{ background: providerAccent(id) }} />
                <span className="project-list-card-provider-label">{label}</span>
              </span>
            );
          })}
        </div>
      ) : null}
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
  const sessions = useActivityStore((s) => s.sessions);

  useLaneLoad(loadProjects);

  useEffect(() => {
    void useActivityStore.getState().load();
  }, [bridgeReady, fixtureMode]);

  const statsByProjectId = useMemo(() => {
    const map = new Map<string, ProjectCardStats>();
    for (const project of projects ?? []) {
      map.set(project.id, { sessionCount: 0, totalCostUsd: 0, providers: [] });
    }
    for (const session of sessions) {
      for (const project of projects ?? []) {
        if (!projectMatchesSession(project, session.title)) continue;
        const entry = map.get(project.id)!;
        entry.sessionCount += 1;
        entry.totalCostUsd += session.costUsd;
        if (!entry.providers.includes(session.provider)) {
          entry.providers.push(session.provider);
        }
      }
    }
    return map;
  }, [projects, sessions]);

  if (loading && projects === null) {
    return <ProjectsSkeleton />;
  }

  const offline = !fixtureMode && !bridge && !loading;
  if (offline) {
    return (
      <OfflineNotice
        status={status}
        summary="Projects need the local daemon before workspace indexes can load."
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
  if (list.length === 0) {
    return <p className="muted">No projects indexed</p>;
  }

  const sourceLabel = fixtureMode ? 'fixture transcript' : 'live daemon project list';

  return (
    <>
      <p className="muted data-source">{`Data source: ${sourceLabel}`}</p>
      <div className="project-list-grid">
        {list.map((project) => (
          <ProjectListCard
            key={project.id}
            project={project}
            stats={statsByProjectId.get(project.id) ?? { sessionCount: 0, totalCostUsd: 0, providers: [] }}
          />
        ))}
      </div>
    </>
  );
}