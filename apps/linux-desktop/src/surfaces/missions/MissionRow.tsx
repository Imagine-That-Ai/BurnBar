import type { CSSProperties } from 'react';
import { useId, useState } from 'react';
import type {
  MissionDetail,
  PendingApproval,
  MissionHealthResult
} from '../../tauriBridge.js';
import {
  formatMissionApprovalLabel,
  formatMissionLifecycleLabel,
  formatRelativeTime,
  missionApprovalAccent,
  missionApprovalDisplay,
  missionGateCode,
  missionLifecycleAccent,
  normalizeMissionLifecycle,
  type MissionRecord
} from './missionGroups.js';
import type { ApprovalDecisionState } from '../../state/missionsStore.js';

export type MissionRowMission = MissionRecord;

export function MissionRow({
  mission,
  pendingApprovals,
  onInspectLogs,
  detail,
  detailLoading = false,
  detailError,
  health,
  healthLoading = false,
  healthError,
  cancelState,
  resumeState,
  onInspect,
  onCancel,
  onResume
}: {
  mission: MissionRowMission;
  pendingApprovals: PendingApproval[];
  onInspectLogs?: (missionId: string) => void;
  detail?: MissionDetail;
  detailLoading?: boolean;
  detailError?: string | null;
  health?: MissionHealthResult;
  healthLoading?: boolean;
  healthError?: string | null;
  cancelState?: ApprovalDecisionState;
  resumeState?: ApprovalDecisionState;
  onInspect?: (missionId: string) => void;
  onCancel?: (missionId: string, note?: string) => void;
  onResume?: (missionId: string, title: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const [confirmCancel, setConfirmCancel] = useState(false);
  const detailsId = useId();
  const lifecycle = normalizeMissionLifecycle(mission.state);
  const snapshot = detail ?? mission;
  const lifecycleAccent = missionLifecycleAccent(lifecycle);
  const approval = missionApprovalDisplay(mission.id, pendingApprovals);
  const approvalAccent = missionApprovalAccent(approval);
  const gate = missionGateCode(mission.id);
  const inspectMission = onInspectLogs ?? onInspect;

  const primaryAction = (() => {
    if (approval === 'pending') {
      return {
        label: 'Review approval',
        hint: 'Scroll to Pending approvals above to approve or deny this gate.'
      };
    }
    if (lifecycle === 'planned') {
      return {
        label: 'Start mission',
        hint: 'Dispatches a daemon-owned packet after approval and runtime readiness checks.'
      };
    }
    if (lifecycle === 'blocked' || lifecycle === 'partial') {
      return {
        label: 'Resume',
        hint: 'Dispatches a fresh daemon-owned packet after approval and runtime readiness checks.'
      };
    }
    return null;
  })();

  const dispatchUnavailable =
    primaryAction !== null && primaryAction.label !== 'Review approval' && !onResume;

  return (
    <li
      className="missions-gate-card"
      data-mission-id={mission.id}
      data-lifecycle={lifecycle}
      style={{ '--missions-lifecycle-accent': lifecycleAccent } as CSSProperties}
    >
      <div className="missions-gate-stripe" aria-hidden="true">
        <span className="missions-gate-stripe-kicker">Gate</span>
        <span className="missions-gate-stripe-code">{gate}</span>
      </div>
      <div className="missions-gate-body">
        <header className="missions-gate-header">
          <p className="missions-gate-meta muted">
            {mission.projectSlug ? (
              <>
                <span className="mono">{mission.projectSlug}</span>
                <span aria-hidden="true"> · </span>
              </>
            ) : null}
            <span>
              {mission.laneCount} {mission.laneCount === 1 ? 'lane' : 'lanes'}
            </span>
            <span aria-hidden="true"> · </span>
            <time dateTime={mission.updatedAt}>{formatRelativeTime(mission.updatedAt)}</time>
          </p>
          <h4 className="missions-gate-title">{mission.title}</h4>
          <div className="missions-gate-badges">
            <span
              className="missions-gate-badge"
              role="status"
              style={{ '--missions-badge-accent': lifecycleAccent } as CSSProperties}
            >
              {formatMissionLifecycleLabel(lifecycle)}
            </span>
            <span
              className="missions-gate-badge missions-gate-badge--approval"
              role="status"
              style={{ '--missions-badge-accent': approvalAccent } as CSSProperties}
            >
              {formatMissionApprovalLabel(approval)}
            </span>
          </div>
        </header>

        {expanded ? (
          <div className="missions-gate-details" id={detailsId}>
            {detailLoading ? (
              <p className="muted" role="status" aria-busy="true">Loading mission detail…</p>
            ) : null}
            {detailError ? (
              <p className="missions-detail-unavailable" role="status">
                Detail refresh unavailable: {detailError}. Showing the last daemon list snapshot.
              </p>
            ) : null}
            <dl className="missions-gate-detail-list">
              <div>
                <dt>Mission id</dt>
                <dd>{mission.id}</dd>
              </div>
              {mission.projectSlug ? (
                <div>
                  <dt>Project</dt>
                  <dd>{mission.projectSlug}</dd>
                </div>
              ) : null}
              <div>
                <dt>Raw state</dt>
                <dd>{mission.state}</dd>
              </div>
              <div>
                <dt>Updated</dt>
                <dd>
                  <time dateTime={snapshot.updatedAt}>{snapshot.updatedAt || 'Unavailable'}</time>
                </dd>
              </div>
              {snapshot.createdAt ? (
                <div>
                  <dt>Created</dt>
                  <dd><time dateTime={snapshot.createdAt}>{snapshot.createdAt}</time></dd>
                </div>
              ) : null}
              {snapshot.recommendation ? (
                <div>
                  <dt>Recommendation</dt>
                  <dd>{snapshot.recommendation}</dd>
                </div>
              ) : null}
              <div>
                <dt>Freshness</dt>
                <dd>{snapshot.freshness === 'fresh' ? 'Fresh' : snapshot.freshness === 'stale' ? 'Stale' : 'Unknown'}</dd>
              </div>
              <div>
                <dt>Runtime health</dt>
                <dd>
                  {healthLoading ? 'Checking…' : health
                    ? `${health.health.status} — ${health.health.detail}`
                    : healthError
                      ? `Unavailable: ${healthError}`
                      : 'Health check not requested.'}
                </dd>
              </div>
            </dl>
            {snapshot.summary ? <p className="missions-detail-summary">{snapshot.summary}</p> : null}

            <section className="missions-detail-section" aria-labelledby={`${detailsId}-packets`}>
              <h5 id={`${detailsId}-packets`}>Packets / tasks</h5>
              {(snapshot.packets ?? []).length > 0 ? (
                <ul className="missions-detail-list">
                  {(snapshot.packets ?? []).map((packet) => (
                    <li key={packet.id}>
                      <strong>{packet.workerName}</strong>
                      <span>{packet.objective}</span>
                      <span className="muted">{packet.status}{packet.runId ? ` · run ${packet.runId}` : ''}</span>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="muted">No packet/task records are present in this snapshot.</p>
              )}
            </section>

            <section className="missions-detail-section" aria-labelledby={`${detailsId}-results`}>
              <h5 id={`${detailsId}-results`}>Results / evidence</h5>
              {(snapshot.results ?? []).length > 0 ? (
                <ul className="missions-detail-list">
                  {(snapshot.results ?? []).map((result) => (
                    <li key={result.id}>
                      <strong>{result.summary}</strong>
                      <span>{result.status}{result.detail ? ` · ${result.detail}` : ''}</span>
                      {result.evidenceRefs.length > 0 ? (
                        <span className="muted">Evidence: {result.evidenceRefs.join(', ')}</span>
                      ) : (
                        <span className="muted">Evidence references unavailable.</span>
                      )}
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="muted">No result/evidence records are present in this snapshot.</p>
              )}
            </section>

            <section className="missions-detail-section" aria-labelledby={`${detailsId}-history`}>
              <h5 id={`${detailsId}-history`}>Controller history</h5>
              {(health?.history ?? []).length > 0 ? (
                <ul className="missions-detail-list">
                  {(health?.history ?? []).map((entry) => (
                    <li key={entry.id}>
                      <strong>{entry.kind} · {entry.status}</strong>
                      <span>{entry.summary}</span>
                      <span className="muted">{entry.occurredAt || 'Timestamp unavailable'}</span>
                    </li>
                  ))}
                </ul>
              ) : (snapshot.takeoverHistory ?? []).length > 0 ? (
                <ul className="missions-detail-list">
                  {(snapshot.takeoverHistory ?? []).map((record) => (
                    <li key={record.id}>
                      <strong>{record.status}</strong>
                      <span>{record.reason}</span>
                      <span className="muted">{record.updatedAt || record.createdAt || 'Timestamp unavailable'}</span>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="muted">No controller history is present in the daemon projection.</p>
              )}
            </section>
          </div>
        ) : null}

        <div className="missions-gate-actions">
          <div className="missions-gate-action-primary">
            {primaryAction ? (
              <div className="missions-gate-action-primary-wrap">
                <button
                  type="button"
                  className="missions-gate-btn missions-gate-btn--primary"
                  disabled={dispatchUnavailable || resumeState?.pending}
                  title={primaryAction.hint}
                  aria-describedby={dispatchUnavailable ? `${detailsId}-dispatch-hint` : undefined}
                  onClick={() => {
                    if (onResume) onResume(mission.id, mission.title);
                  }}
                >
                  {resumeState?.pending ? 'Dispatching…' : primaryAction.label}
                </button>
                {dispatchUnavailable ? (
                  <p className="missions-gate-dispatch-hint muted" id={`${detailsId}-dispatch-hint`}>
                    {primaryAction.hint}
                  </p>
                ) : null}
              </div>
            ) : null}
            <button
              type="button"
              className="missions-gate-btn missions-gate-btn--secondary"
              onClick={() => {
                setExpanded(true);
                inspectMission?.(mission.id);
              }}
            >
              Inspect logs
            </button>
            {resumeState?.error ? (
              <p className="missions-detail-unavailable" role="alert">{resumeState.error}</p>
            ) : null}
          </div>
          <button
            type="button"
            className="missions-gate-expand"
            aria-expanded={expanded}
            aria-controls={detailsId}
            onClick={() => {
              setExpanded((v) => {
                const next = !v;
                if (next) onInspect?.(mission.id);
                return next;
              });
            }}
          >
            {expanded ? 'Less' : 'Details'}
          </button>
          {onCancel && !['completed', 'cancelled', 'failed'].includes(mission.state.toLowerCase()) ? (
            confirmCancel ? (
              <button
                type="button"
                className="missions-gate-btn missions-gate-btn--danger"
                disabled={cancelState?.pending}
                onClick={() => {
                  setConfirmCancel(false);
                  onCancel(mission.id, 'Cancelled from Linux mission control.');
                }}
              >
                {cancelState?.pending ? 'Cancelling…' : 'Confirm cancel'}
              </button>
            ) : (
              <button
                type="button"
                className="missions-gate-btn missions-gate-btn--secondary"
                disabled={cancelState?.pending}
                onClick={() => setConfirmCancel(true)}
              >
                Cancel mission
              </button>
            )
          ) : null}
          </div>
          {cancelState?.error ? <p className="missions-detail-unavailable" role="alert">{cancelState.error}</p> : null}
        </div>
    </li>
  );
}
