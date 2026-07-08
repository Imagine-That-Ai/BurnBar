import type { CSSProperties } from 'react';
import { useId, useState } from 'react';
import type { PendingApproval } from '../../tauriBridge.js';
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

export type MissionRowMission = MissionRecord;

export function MissionRow({
  mission,
  pendingApprovals,
  onInspectLogs
}: {
  mission: MissionRowMission;
  pendingApprovals: PendingApproval[];
  onInspectLogs?: (missionId: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const detailsId = useId();
  const lifecycle = normalizeMissionLifecycle(mission.state);
  const lifecycleAccent = missionLifecycleAccent(lifecycle);
  const approval = missionApprovalDisplay(mission.id, pendingApprovals);
  const approvalAccent = missionApprovalAccent(approval);
  const gate = missionGateCode(mission.id);

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
        hint: 'Available when the daemon exposes mission dispatch from the Linux shell.'
      };
    }
    if (lifecycle === 'blocked' || lifecycle === 'partial') {
      return {
        label: 'Resume',
        hint: 'Resume and takeover run on the controller runtime — use a paired macOS device or daemon CLI.'
      };
    }
    return null;
  })();

  const dispatchUnavailable =
    primaryAction !== null && primaryAction.label !== 'Review approval';

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
                  <time dateTime={mission.updatedAt}>{mission.updatedAt}</time>
                </dd>
              </div>
            </dl>
          </div>
        ) : null}

        <div className="missions-gate-actions">
          <div className="missions-gate-action-primary">
            {primaryAction ? (
              <div className="missions-gate-action-primary-wrap">
                <button
                  type="button"
                  className="missions-gate-btn missions-gate-btn--primary"
                  disabled={dispatchUnavailable}
                  title={primaryAction.hint}
                  aria-describedby={dispatchUnavailable ? `${detailsId}-dispatch-hint` : undefined}
                >
                  {primaryAction.label}
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
              onClick={() => onInspectLogs?.(mission.id)}
            >
              Inspect logs
            </button>
          </div>
          <button
            type="button"
            className="missions-gate-expand"
            aria-expanded={expanded}
            aria-controls={detailsId}
            onClick={() => setExpanded((v) => !v)}
          >
            {expanded ? 'Less' : 'Details'}
          </button>
        </div>
      </div>
    </li>
  );
}