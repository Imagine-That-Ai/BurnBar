import { useState } from 'react';
import type { PendingApproval } from '../../tauriBridge.js';
import { Banner } from '../../components/Banner.js';
import type { ApprovalDecisionState } from '../../state/missionsStore.js';
import { formatRelativeTime } from './missionGroups.js';

export function ApprovalCard({
  approval,
  missionTitle,
  decisionState,
  onApprove,
  onDeny
}: {
  approval: PendingApproval;
  missionTitle: string;
  decisionState: ApprovalDecisionState | undefined;
  onApprove: () => void;
  onDeny: () => void;
}) {
  const [confirmHighRisk, setConfirmHighRisk] = useState(false);
  const pending = decisionState?.pending ?? false;
  const error = decisionState?.error ?? null;
  const isHighRisk = approval.risk === 'high';

  const handleApproveClick = () => {
    if (isHighRisk && !confirmHighRisk) {
      setConfirmHighRisk(true);
      return;
    }
    onApprove();
  };

  const handleDenyClick = () => {
    setConfirmHighRisk(false);
    onDeny();
  };

  const riskClass =
    approval.risk === 'high' ? 'missions-risk missions-risk-high' : 'missions-risk missions-risk-standard';

  return (
    <article className="missions-approval" data-approval-id={approval.id}>
      <header className="missions-approval-header">
        <p className="missions-approval-summary">{approval.summary}</p>
        <span className={riskClass}>{approval.risk === 'high' ? 'High risk' : 'Standard risk'}</span>
      </header>
      <p className="muted missions-approval-meta">
        Mission: {missionTitle} · Requested{' '}
        <time dateTime={approval.requestedAt}>{formatRelativeTime(approval.requestedAt)}</time>
      </p>
      {error ? (
        <Banner tone="degraded" role="alert">
          {error}
        </Banner>
      ) : null}
      {pending ? (
        <p className="missions-approval-pending" role="status" aria-busy="true">
          Submitting decision…
        </p>
      ) : null}
      <div className="actions missions-approval-actions">
        {isHighRisk && confirmHighRisk ? (
          <button
            type="button"
            className="primary"
            disabled={pending}
            onClick={onApprove}
            aria-label={`Confirm approve for ${missionTitle}`}
          >
            Confirm approve
          </button>
        ) : (
          <button
            type="button"
            className="primary"
            disabled={pending}
            onClick={handleApproveClick}
            aria-label={`Approve ${missionTitle}`}
          >
            Approve
          </button>
        )}
        <button
          type="button"
          className="ghost"
          disabled={pending}
          onClick={handleDenyClick}
          aria-label={`Deny ${missionTitle}`}
        >
          Deny
        </button>
      </div>
    </article>
  );
}