import { useId, useState } from 'react';
import { PLAN_TIER_LABEL, type AccountPlanTier } from './accountPlanTier.js';

const TRUST_LABEL = 'Linux · lower-trust identity';

const TRUST_RUNBOOK_URL =
  'https://github.com/openburnbar/openburnbar/blob/main/docs/linux-port/cloud-security-runbook.md';

const DISCLOSURE_COPY =
  'This Linux shell is a lower-trust principal. High-risk actions—billing changes, credential rotation, and destructive cloud operations—require step-up approval on a trusted device.';

export function TrustBadge({ planTier }: { planTier: AccountPlanTier }) {
  const [open, setOpen] = useState(false);
  const disclosureId = useId();

  return (
    <div className="account-trust">
      <div className="account-trust-primary">
        <span className="trust-badge">{TRUST_LABEL}</span>
        <button
          type="button"
          className="trust-disclosure-toggle"
          aria-expanded={open}
          aria-controls={disclosureId}
          onClick={() => setOpen((v) => !v)}
        >
          {open ? 'Hide trust limits' : 'What does lower-trust limit?'}
        </button>
      </div>
      <span className="account-plan-tier-chip" data-plan-tier={planTier}>
        Plan · {PLAN_TIER_LABEL[planTier]}
      </span>
      {open ? (
        <div id={disclosureId} className="trust-disclosure-panel">
          <p className="trust-disclosure muted">{DISCLOSURE_COPY}</p>
          <p className="trust-disclosure-footer muted">
            <a
              className="trust-runbook-link"
              href={TRUST_RUNBOOK_URL}
              target="_blank"
              rel="noopener noreferrer"
            >
              Linux cloud security runbook
            </a>
          </p>
        </div>
      ) : null}
    </div>
  );
}