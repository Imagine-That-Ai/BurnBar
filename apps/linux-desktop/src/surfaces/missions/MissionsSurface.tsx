import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { fixtureProjects } from '../../daemonFixture.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useMissionsStore } from '../../state/missionsStore.js';
import type { ProjectEntry } from '../../tauriBridge.js';
import { ApprovalCard } from './ApprovalCard.js';
import { ControllerSummary } from './ControllerSummary.js';
import { MissionRow } from './MissionRow.js';
import { MissionStateChipRail } from './MissionStateChip.js';
import { NewMissionSheet } from './NewMissionSheet.js';
import { RunwayInsignia } from './RunwayInsignia.js';
import { buildProjectFilterOptions } from './MissionProjectFilter.js';
import {
  filterAndGroupMissions,
  knownMissionProjects,
  missionMatchesFilter,
  missionMatchesProject,
  missionTitleById,
  runwayStripStats,
  sortMissionsForDisplay,
  type MissionStateFilterKey
} from './missionGroups.js';
import './missions.css';

const APPROVAL_POLL_MS = 30_000;

export function MissionsSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();
  const data = useMissionsStore((s) => s.data);
  const loading = useMissionsStore((s) => s.loading);
  const error = useMissionsStore((s) => s.error);
  const approvalById = useMissionsStore((s) => s.approvalById);
  const cancelById = useMissionsStore((s) => s.cancelById);
  const detailById = useMissionsStore((s) => s.detailById);
  const detailLoadingById = useMissionsStore((s) => s.detailLoadingById);
  const detailErrorById = useMissionsStore((s) => s.detailErrorById);
  const load = useMissionsStore((s) => s.load);
  const inspect = useMissionsStore((s) => s.inspect);
  const decide = useMissionsStore((s) => s.decide);
  const cancelMission = useMissionsStore((s) => s.cancel);
  const [liveMessage, setLiveMessage] = useState('');
  const [stateFilter, setStateFilter] = useState<MissionStateFilterKey>('all');
  const [projectFilter, setProjectFilter] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [newMissionOpen, setNewMissionOpen] = useState(false);
  const [projects, setProjects] = useState<ProjectEntry[] | null>(null);

  useLaneLoad(load);

  useEffect(() => {
    const id = window.setInterval(() => {
      if (!document.hidden) {
        void load();
      }
    }, APPROVAL_POLL_MS);
    return () => window.clearInterval(id);
  }, [load]);

  useEffect(() => {
    if (fixtureMode) {
      setProjects(fixtureProjects());
      return;
    }
    if (!bridge) {
      setProjects(null);
      return;
    }
    if (typeof bridge.projectList !== 'function') {
      setProjects(null);
      return;
    }
    let cancelled = false;
    void bridge.projectList().then((list) => {
      if (!cancelled) setProjects(list);
    });
    return () => {
      cancelled = true;
    };
  }, [bridge, fixtureMode]);

  const runDecision = useCallback(
    async (approvalId: string, decision: 'approve' | 'deny', missionTitle: string) => {
      await decide(approvalId, decision);
      const after = useMissionsStore.getState().approvalById[approvalId];
      if (after && !after.pending && !after.error) {
        const verb = decision === 'approve' ? 'Approved' : 'Denied';
        setLiveMessage(`${verb}: ${missionTitle}`);
      }
    },
    [decide]
  );

  const refreshRuntime = useCallback(async () => {
    if (refreshing) return;
    setRefreshing(true);
    try {
      await load();
    } finally {
      setRefreshing(false);
    }
  }, [load, refreshing]);

  const packagedOffline =
    !fixtureMode && error === 'Packaged shell required for live data.' && !loading;

  const missions = data?.missions ?? [];
  const pendingApprovals = data?.pendingApprovals ?? [];

  const runCancellation = useCallback(
    async (missionId: string, note?: string) => {
      const ok = await cancelMission(missionId, note);
      if (ok) {
        const title = missions.find((mission) => mission.id === missionId)?.title ?? missionId;
        setLiveMessage(`Cancelled: ${title}`);
      }
    },
    [cancelMission, missions]
  );

  const missionsForProject = useMemo(
    () => missions.filter((m) => missionMatchesProject(m, projectFilter)),
    [missions, projectFilter]
  );

  const projectOptions = useMemo(
    () => buildProjectFilterOptions(knownMissionProjects(missions), projects),
    [missions, projects]
  );

  const groups = useMemo(
    () => filterAndGroupMissions(missionsForProject, stateFilter, pendingApprovals),
    [missionsForProject, stateFilter, pendingApprovals]
  );
  const flatFiltered = useMemo(() => {
    const filtered = missionsForProject.filter((m) => missionMatchesFilter(m, stateFilter, pendingApprovals));
    return sortMissionsForDisplay(filtered, pendingApprovals);
  }, [missionsForProject, stateFilter, pendingApprovals]);
  const runwayStats = runwayStripStats(missionsForProject);
  const showGroupedSections = stateFilter === 'all';

  const renderMissionRow = (mission: (typeof missions)[number]) => (
    <MissionRow
      key={mission.id}
      mission={mission}
      pendingApprovals={pendingApprovals}
      detail={detailById[mission.id]}
      detailLoading={detailLoadingById[mission.id] ?? false}
      detailError={detailErrorById[mission.id]}
      cancelState={cancelById[mission.id]}
      onInspect={(id) => void inspect(id)}
      onCancel={fixtureMode ? undefined : (id, note) => void runCancellation(id, note)}
    />
  );

  if (loading && !data) {
    return (
      <p className="missions-loading muted" role="status" aria-busy="true">
        Loading missions…
      </p>
    );
  }

  if (packagedOffline) {
    return (
      <OfflineNotice
        status={status}
        summary="Missions need the packaged shell before mission lists and approval decisions can load."
        fixtureMode={fixtureMode}
      />
    );
  }

  if (error && !data) {
    return (
      <Banner tone="degraded" role="alert">
        <p>{error}</p>
        <button type="button" onClick={() => void load()}>
          Retry
        </button>
      </Banner>
    );
  }

  if (!data) {
    return null;
  }

  const isEmpty = missions.length === 0 && pendingApprovals.length === 0;

  return (
    <div className="missions-surface">
      <div className="visually-hidden" aria-live="assertive" aria-atomic="true">
        {liveMessage}
      </div>

      <header className="missions-control-header">
        <div className="missions-control-header-copy">
          <div className="missions-control-kicker-row">
            <RunwayInsignia size={28} />
            <p className="missions-control-kicker">MISSION · CONTROL</p>
          </div>
          <h2 className="missions-control-title">Missions lane</h2>
          <p className="muted missions-control-subtitle">
            Flight-ops runway for mission state, approvals, and controller runtime refresh.
          </p>
        </div>
        <div className="missions-control-actions">
          <button
            type="button"
            className="missions-btn-file"
            onClick={() => setNewMissionOpen(true)}
          >
            File new mission
          </button>
          <button
            type="button"
            className="missions-btn-refresh"
            onClick={() => void refreshRuntime()}
            disabled={refreshing}
            aria-busy={refreshing}
          >
            {refreshing ? 'Refreshing…' : 'Refresh runtime'}
          </button>
        </div>
      </header>

      <ControllerSummary stats={runwayStats} />

      <MissionStateChipRail
        missions={missionsForProject}
        pendingApprovals={pendingApprovals}
        activeFilter={stateFilter}
        onFilterChange={setStateFilter}
        projectFilter={projectFilter}
        projectOptions={projectOptions}
        onProjectFilterChange={setProjectFilter}
      />

      {pendingApprovals.length > 0 ? (
        <section className="missions-section" aria-labelledby="missions-approvals-heading">
          <h3 id="missions-approvals-heading">Pending approvals</h3>
          <div className="missions-approval-list">
            {pendingApprovals.map((approval) => {
              const missionTitle = missionTitleById(missions, approval.missionId);
              return (
                <ApprovalCard
                  key={approval.id}
                  approval={approval}
                  missionTitle={missionTitle}
                  decisionState={approvalById[approval.id]}
                  onApprove={() => void runDecision(approval.id, 'approve', missionTitle)}
                  onDeny={() => void runDecision(approval.id, 'deny', missionTitle)}
                />
              );
            })}
          </div>
        </section>
      ) : null}

      {isEmpty ? (
        <p className="missions-empty muted" role="status">
          No missions — dispatch from the daemon or a paired device.
        </p>
      ) : flatFiltered.length === 0 ? (
        <p className="missions-empty muted" role="status">
          No missions match this filter.
        </p>
      ) : showGroupedSections ? (
        groups.map((group) => (
          <section
            key={group.key}
            className="missions-section"
            aria-labelledby={`missions-group-${group.key}`}
          >
            <h3 id={`missions-group-${group.key}`}>{group.label}</h3>
            <ul className="missions-gate-list">
              {group.missions.map((mission) => renderMissionRow(mission))}
            </ul>
          </section>
        ))
      ) : (
        <section className="missions-section" aria-labelledby="missions-filtered-heading">
          <h3 id="missions-filtered-heading" className="visually-hidden">
            Filtered missions
          </h3>
          <ul className="missions-gate-list">
            {flatFiltered.map((mission) => renderMissionRow(mission))}
          </ul>
        </section>
      )}

      <p className="muted missions-provenance">
        {fixtureMode ? 'fixture transcript' : 'live daemon mission list'}
      </p>

      <NewMissionSheet
        open={newMissionOpen}
        onClose={() => setNewMissionOpen(false)}
        projects={projects ?? []}
        defaultProjectSlug={projectFilter}
        onSubmitted={() => void refreshRuntime()}
      />
    </div>
  );
}
