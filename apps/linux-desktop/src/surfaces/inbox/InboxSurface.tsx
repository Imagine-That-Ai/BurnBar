import { useEffect, useState } from 'react';
import {
  activityConversationRouteHash,
  inboxSelectionFromHash,
  projectWorkspaceRouteHash
} from '../../routes.js';
import { useInboxStore, type InboxFilter } from '../../state/inboxStore.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useShellStore } from '../../state/shellStore.js';
import type {
  AIInboxAction,
  AIInboxEvidence,
  AIInboxFeedback,
  AIInboxItemDetail,
  AIInboxItemSummary,
  AIInboxPlan,
  AIInboxPlanCandidate,
  AIInboxPlanStep,
  AIInboxPresentationRow,
  AIInboxThreadMessage
} from '../../tauriBridge.js';
import './inbox.css';

const FILTERS: Array<{ id: InboxFilter; label: string }> = [
  { id: 'active', label: 'Active' },
  { id: 'attention', label: 'Needs attention' },
  { id: 'resolved', label: 'Resolved' },
  { id: 'archived', label: 'Archived' }
];

const KIND_LABELS: Record<string, string> = {
  ci_waste: 'CI waste',
  promised_not_landed: 'Not landed',
  uncommitted_work: 'Uncommitted work',
  cost_anomaly: 'Cost anomaly',
  stuck_pr: 'Stuck PR',
  index_health: 'Index health',
  brief: 'Brief',
  budget: 'Budget',
  system: 'System'
};

type InboxListSection = {
  id: 'attention' | 'today' | 'earlier' | 'closed';
  label: string;
  rows: AIInboxPresentationRow[];
};

export function inboxListSections(
  rows: AIInboxPresentationRow[],
  filter: InboxFilter = 'active',
  now = Date.now()
): InboxListSection[] {
  if (filter === 'resolved' || filter === 'archived') {
    return rows.length > 0 ? [{ id: 'closed', label: 'Closed', rows }] : [];
  }
  const current = new Date(now);
  const today = new Date(
    current.getFullYear(),
    current.getMonth(),
    current.getDate()
  ).getTime();
  const attention: AIInboxPresentationRow[] = [];
  const todayRows: AIInboxPresentationRow[] = [];
  const earlier: AIInboxPresentationRow[] = [];

  for (const row of rows) {
    const summary = row.item.summary;
    if (summary.priority <= 2) {
      attention.push(row);
      continue;
    }
    const lastSeenAt = Date.parse(summary.lastSeenAt);
    if (Number.isFinite(lastSeenAt) && lastSeenAt >= today) {
      todayRows.push(row);
    } else {
      earlier.push(row);
    }
  }

  const sections: InboxListSection[] = [
    { id: 'attention', label: 'Needs attention', rows: attention },
    { id: 'today', label: 'Today', rows: todayRows },
    { id: 'earlier', label: 'Earlier', rows: earlier }
  ];
  return sections.filter((section) => section.rows.length > 0);
}

function relativeTime(value: string): string {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return 'unknown time';
  const delta = timestamp - Date.now();
  const minutes = Math.round(delta / 60_000);
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
  if (Math.abs(minutes) < 60) return formatter.format(minutes, 'minute');
  const hours = Math.round(minutes / 60);
  if (Math.abs(hours) < 48) return formatter.format(hours, 'hour');
  return formatter.format(Math.round(hours / 24), 'day');
}

function priorityLabel(priority: number): string {
  return `P${Math.min(4, Math.max(1, Math.round(priority)))}`;
}

function InboxListRow({
  item,
  selected,
  unread,
  onSelect
}: {
  item: AIInboxItemSummary;
  selected: boolean;
  unread: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      className={`inbox-row${selected ? ' inbox-row--selected' : ''}${unread ? ' inbox-row--unread' : ''}`}
      aria-current={selected ? 'true' : undefined}
      aria-label={`${priorityLabel(item.priority)} ${item.title}`}
      onClick={onSelect}
    >
      <span className="inbox-row__top">
        <span className="inbox-row__kind">
          {unread ? <span className="inbox-unread-dot" aria-label="Unread" /> : null}
          {KIND_LABELS[item.kind] ?? item.kind}
        </span>
        <span className={`inbox-priority inbox-priority--${priorityLabel(item.priority).toLowerCase()}`}>
          {priorityLabel(item.priority)}
        </span>
      </span>
      <strong>{item.title}</strong>
      <span className="inbox-row__meta">
        {item.projectName ? `${item.projectName} · ` : ''}
        {relativeTime(item.lastSeenAt)}
        {item.occurrenceCount > 1 ? ` · ${item.occurrenceCount}×` : ''}
      </span>
    </button>
  );
}

async function openInboxExternalUrl(url: string): Promise<void> {
  const shell = useShellStore.getState();
  if (!shell.bridge?.openInboxExternalUrl) {
    throw new Error('The installed Linux shell cannot safely open Inbox links.');
  }
  await shell.bridge.openInboxExternalUrl(url);
}

function reportActionFailure(cause: unknown): void {
  useInboxStore.getState().reportActionError(
    cause instanceof Error ? cause.message : 'Could not open this Inbox destination.'
  );
}

function EvidenceRow({ evidence }: { evidence: AIInboxEvidence }) {
  const content = (
    <>
      <span className="inbox-evidence__glyph" aria-hidden="true">↗</span>
      <span>
        <strong>{evidence.label}</strong>
        {evidence.detail ? <small>{evidence.detail}</small> : null}
      </span>
    </>
  );
  if (!evidence.url) return <div className="inbox-evidence">{content}</div>;
  return (
    <button
      type="button"
      className="inbox-evidence"
      onClick={() => void openInboxExternalUrl(evidence.url!).catch(reportActionFailure)}
    >
      {content}
    </button>
  );
}

async function performItemAction(action: AIInboxAction): Promise<void> {
  if (action.kind === 'open_url') {
    await openInboxExternalUrl(action.value);
    return;
  }
  if (action.kind === 'open_settings') {
    useShellStore.getState().setRoute('settings');
    return;
  }
  if (action.kind === 'open_project') {
    useShellStore.getState().navigateDestination({
      route: 'projects',
      hash: projectWorkspaceRouteHash(action.value)
    });
    return;
  }
  if (action.kind === 'open_session_log' || action.kind === 'resume_conversation') {
    useShellStore.getState().navigateDestination({
      route: 'activity',
      hash: activityConversationRouteHash(action.value)
    });
    return;
  }
  if (action.kind === 'run_command') {
    void navigator.clipboard?.writeText(action.value);
  }
}

function actionButtonLabel(action: AIInboxAction): string {
  if (action.kind === 'run_command') return `Copy: ${action.title}`;
  if (action.kind === 'open_project') return 'Open project';
  if (action.kind === 'open_session_log') return 'Open session';
  if (action.kind === 'resume_conversation') return 'Resume conversation';
  return action.title;
}

function MemoryCandidateCard({
  candidate,
  itemID,
  fingerprint
}: {
  candidate: AIInboxItemDetail['payload']['memoryCandidates'][number];
  itemID: string;
  fingerprint: string;
}) {
  const approveMemoryCandidate = useInboxStore((state) => state.approveMemoryCandidate);
  const busy = useInboxStore(
    (state) => state.busy[`memory:${itemID}:${candidate.id}`] ?? false
  );
  const [state, setState] = useState<'pending' | 'approved' | 'dismissed'>('pending');
  if (state === 'dismissed') {
    return (
      <article className="inbox-memory-candidate inbox-memory-candidate--dismissed">
        <strong>Proposal dismissed</strong>
        <button type="button" className="ghost" onClick={() => setState('pending')}>Undo</button>
      </article>
    );
  }
  return (
    <article className="inbox-memory-candidate">
      <strong>{candidate.kind}</strong>
      <p>{candidate.text}</p>
      <span>{Math.round(candidate.confidence * 100)}% confidence</span>
      <div className="inbox-actions">
        <button
          type="button"
          className="ghost"
          disabled={busy || state === 'approved'}
          aria-busy={busy}
          onClick={() => {
            void approveMemoryCandidate(itemID, fingerprint, candidate.id).then((approved) => {
              if (approved) setState('approved');
            });
          }}
        >
          {state === 'approved' ? 'Saved to memory' : busy ? 'Remembering…' : 'Remember this'}
        </button>
        {state === 'pending' ? (
          <button type="button" className="ghost" disabled={busy} onClick={() => setState('dismissed')}>
            Dismiss
          </button>
        ) : null}
      </div>
      <small className="muted">
        {state === 'approved'
          ? 'Saved through the same quarantine-first memory authority used by the rest of OpenBurnBar.'
          : 'Nothing enters memory until you approve it.'}
      </small>
    </article>
  );
}

function PlanCandidateCard({
  candidate,
  messageID
}: {
  candidate: AIInboxPlanCandidate;
  messageID: string;
}) {
  const acceptCandidate = useInboxStore((state) => state.acceptCandidate);
  const busy = useInboxStore((state) => state.busy[`accept:${candidate.planID ?? 'new'}:${candidate.title}`] ?? false);
  const [accepted, setAccepted] = useState(false);
  return (
    <div className="inbox-plan-candidate">
      <span className="inbox-section-label">Proposed plan step · {candidate.horizon}</span>
      <strong>{candidate.title}</strong>
      <p>{candidate.bodyMarkdown}</p>
      <button
        type="button"
        className="primary"
        disabled={busy || accepted}
        aria-busy={busy}
        onClick={() => {
          void acceptCandidate(candidate).then((ok) => {
            if (ok) setAccepted(true);
          });
        }}
      >
        {accepted ? 'Accepted into plan' : busy ? 'Accepting…' : 'Accept into plan'}
      </button>
      <span className="sr-only">Proposal from thread message {messageID}</span>
    </div>
  );
}

function ThreadMessage({ message }: { message: AIInboxThreadMessage }) {
  return (
    <article className={`inbox-thread-message inbox-thread-message--${message.role}`}>
      <header>
        <strong>{message.role === 'user' ? 'You' : 'Inbox'}</strong>
        {message.modelProvenance ? <span>{message.modelProvenance}</span> : null}
        {message.costUSD > 0 ? <span>${message.costUSD.toFixed(3)}</span> : null}
      </header>
      <p>{message.bodyMarkdown}</p>
      {message.planCandidates.map((candidate) => (
        <PlanCandidateCard key={`${message.id}:${candidate.title}`} candidate={candidate} messageID={message.id} />
      ))}
    </article>
  );
}

function InboxThread({ fingerprint }: { fingerprint: string }) {
  const thread = useInboxStore((state) => state.threads[fingerprint]);
  const sendReply = useInboxStore((state) => state.sendReply);
  const refusalReason = useInboxStore((state) => state.refusalReason);
  const sending = useInboxStore((state) => state.busy[`reply:${fingerprint}`] ?? false);
  const [draft, setDraft] = useState('');

  return (
    <section className="inbox-detail-section" aria-labelledby="inbox-discuss-heading">
      <div className="inbox-section-heading">
        <h3 id="inbox-discuss-heading">Discuss</h3>
        {thread && thread.totalCostUSD > 0 ? <span>${thread.totalCostUSD.toFixed(3)} total</span> : null}
      </div>
      <div className="inbox-thread">
        {thread?.messages.map((message) => <ThreadMessage key={message.id} message={message} />)}
      </div>
      {refusalReason ? <p className="inbox-inline-alert" role="alert">{refusalReason}</p> : null}
      <form
        className="inbox-composer"
        onSubmit={(event) => {
          event.preventDefault();
          const body = draft.trim();
          if (!body) return;
          void sendReply(fingerprint, body).then((response) => {
            if (response && !response.refusalReason) setDraft('');
          });
        }}
      >
        <label className="sr-only" htmlFor="inbox-reply">Ask about this item</label>
        <textarea
          id="inbox-reply"
          value={draft}
          rows={2}
          maxLength={8_000}
          placeholder="Ask about this item…"
          disabled={sending}
          onChange={(event) => setDraft(event.currentTarget.value)}
        />
        <button type="submit" className="primary" disabled={sending || !draft.trim()}>
          {sending ? 'Sending…' : 'Send'}
        </button>
      </form>
    </section>
  );
}

function PlanStepRow({ plan, step }: { plan: AIInboxPlan; step: AIInboxPlanStep }) {
  const busy = useInboxStore((state) => state.busy[`step:${step.id}`] ?? false);
  const promoteStep = useInboxStore((state) => state.promoteStep);
  const updateStep = useInboxStore((state) => state.updateStep);
  const gradeStep = useInboxStore((state) => state.gradeStep);
  const rememberStep = useInboxStore((state) => state.rememberStep);
  const createFollowup = useInboxStore((state) => state.createFollowup);
  const hasSelectedProject = useInboxStore((state) =>
    state.rows.some(
      (row) => row.item.summary.id === state.selectedID && Boolean(row.item.summary.projectID)
    )
  );
  const [grade, setGrade] = useState(step.grade ?? 75);
  return (
    <div className="inbox-plan-step">
      <div>
        <strong>{step.title}</strong>
        <span>{step.status.replaceAll('_', ' ')}</span>
      </div>
      <p>{step.bodyMarkdown}</p>
      <div className="inbox-plan-actions">
        {!step.missionID && (step.status === 'accepted' || step.status === 'in_progress') ? (
          <button type="button" className="ghost" disabled={busy} onClick={() => void promoteStep(plan, step.id)}>
            Promote to mission
          </button>
        ) : null}
        {step.status === 'accepted' || step.status === 'in_progress' ? (
          <button type="button" className="ghost" disabled={busy} onClick={() => void updateStep(step.id, 'landed')}>
            Mark landed
          </button>
        ) : null}
        {!step.followupID && step.status !== 'killed' ? (
          <button
            type="button"
            className="ghost"
            disabled={busy || !hasSelectedProject}
            title={hasSelectedProject ? 'Create a Mission Control follow-up from this step' : 'This item has no project attribution'}
            onClick={() => void createFollowup(step.id)}
          >
            {busy ? 'Working…' : 'Follow up'}
          </button>
        ) : step.followupID ? (
          <span className="inbox-plan-state" title={step.followupID}>Follow-up created</span>
        ) : null}
        <button
          type="button"
          className="ghost"
          disabled={busy || Boolean(step.memoryID)}
          title={step.memoryID ? `Saved as ${step.memoryID}` : 'Save this step through the quarantine-first memory authority'}
          onClick={() => void rememberStep(step.id)}
        >
          {step.memoryID ? 'Remembered' : busy ? 'Working…' : 'Remember'}
        </button>
        <label className="inbox-grade">
          <span>Grade</span>
          <input
            type="number"
            min={0}
            max={100}
            value={grade}
            disabled={busy}
            onChange={(event) => setGrade(Math.min(100, Math.max(0, Number(event.currentTarget.value))))}
          />
          <button type="button" className="ghost" disabled={busy} onClick={() => void gradeStep(step.id, grade)}>
            Save
          </button>
        </label>
      </div>
    </div>
  );
}

function FounderPlans() {
  const plans = useInboxStore((state) => state.plans);
  const plansLoading = useInboxStore((state) => state.plansLoading);
  if (plansLoading) return <p className="muted" role="status">Loading Founder Plans…</p>;
  if (plans.length === 0) return null;
  return (
    <section className="inbox-detail-section" aria-labelledby="inbox-plans-heading">
      <div className="inbox-section-heading">
        <h3 id="inbox-plans-heading">Founder Plans</h3>
        <span>{plans.length} active</span>
      </div>
      <div className="inbox-plans">
        {plans.map((plan) => (
          <article key={plan.id} className="inbox-plan">
            <header>
              <strong>{plan.title}</strong>
              <span>{plan.status}</span>
              {plan.gradeAverage !== null && plan.gradeAverage !== undefined
                ? <span>grade {Math.round(plan.gradeAverage)}</span>
                : null}
            </header>
            {plan.summaryMarkdown ? <p>{plan.summaryMarkdown}</p> : null}
            {plan.steps.map((step) => <PlanStepRow key={step.id} plan={plan} step={step} />)}
          </article>
        ))}
      </div>
    </section>
  );
}

function InboxDispositionControls({ row }: { row: AIInboxPresentationRow }) {
  const itemID = row.item.summary.id;
  const busy = useInboxStore((state) => state.busy[`presentation:${itemID}`] ?? false);
  const toggleRead = useInboxStore((state) => state.toggleRead);
  const setArchived = useInboxStore((state) => state.setArchived);
  const setSnooze = useInboxStore((state) => state.setSnooze);
  const setFeedback = useInboxStore((state) => state.setFeedback);
  const archived = row.presentation.archivedAt !== undefined;
  const feedback = row.presentation.feedback;
  const snoozed = row.presentation.snoozedUntil !== undefined
    && Date.parse(row.presentation.snoozedUntil) > Date.now();

  const toggleFeedback = (value: AIInboxFeedback) => {
    void setFeedback(itemID, feedback === value ? undefined : value);
  };

  return (
    <section className="inbox-disposition" aria-label="Inbox item controls">
      <div className="inbox-disposition__feedback">
        <button
          type="button"
          className="ghost"
          aria-pressed={feedback === 'useful'}
          disabled={busy}
          onClick={() => toggleFeedback('useful')}
        >
          Useful
        </button>
        <button
          type="button"
          className="ghost"
          aria-pressed={feedback === 'not_useful'}
          disabled={busy}
          onClick={() => toggleFeedback('not_useful')}
        >
          Not useful
        </button>
      </div>
      <div className="inbox-disposition__actions">
        <button type="button" className="ghost" disabled={busy} onClick={() => void toggleRead(itemID)}>
          {row.presentation.readAt === undefined ? 'Mark read' : 'Mark unread'}
        </button>
        {snoozed ? (
          <button type="button" className="ghost" disabled={busy} onClick={() => void setSnooze(itemID)}>
            Clear snooze
          </button>
        ) : (
          <select
            aria-label="Snooze inbox item"
            defaultValue=""
            disabled={busy}
            onChange={(event) => {
              const seconds = Number(event.currentTarget.value);
              event.currentTarget.value = '';
              if (seconds > 0) {
                void setSnooze(itemID, new Date(Date.now() + seconds * 1_000).toISOString());
              }
            }}
          >
            <option value="" disabled>Snooze…</option>
            <option value="3600">For an hour</option>
            <option value="86400">Until tomorrow</option>
            <option value="604800">For a week</option>
          </select>
        )}
        <button
          type="button"
          className="ghost"
          disabled={busy}
          onClick={() => void setArchived(itemID, !archived)}
        >
          {archived ? 'Unarchive' : 'Archive'}
        </button>
      </div>
    </section>
  );
}

function InboxDetail({ row }: { row: AIInboxPresentationRow }) {
  const detail = row.item;
  const actionError = useInboxStore((state) => state.actionError);
  const clearActionError = useInboxStore((state) => state.clearActionError);
  const metrics = Object.entries(detail.payload.metrics)
    .filter(([key]) => key !== 'calibration_note')
    .sort(([a], [b]) => a.localeCompare(b));
  return (
    <div className="inbox-detail" data-testid="inbox-detail">
      <header className="inbox-detail__hero">
        <div className="inbox-detail__badges">
          <span>{KIND_LABELS[detail.summary.kind] ?? detail.summary.kind}</span>
          <span className={`inbox-priority inbox-priority--${priorityLabel(detail.summary.priority).toLowerCase()}`}>
            {priorityLabel(detail.summary.priority)}
          </span>
          {detail.summary.state === 'resolved' ? <span className="inbox-resolved">Resolved</span> : null}
        </div>
        <h2>{detail.summary.title}</h2>
        <p className="inbox-detail__meta">
          {detail.summary.projectName ? `${detail.summary.projectName} · ` : ''}
          first seen {relativeTime(detail.summary.firstSeenAt)}
          {detail.summary.occurrenceCount > 1 ? ` · seen ${detail.summary.occurrenceCount} times` : ''}
        </p>
        {detail.summary.resolutionNote ? <p className="inbox-resolution-note">{detail.summary.resolutionNote}</p> : null}
      </header>

      {actionError ? (
        <div className="inbox-inline-alert" role="alert">
          <span>{actionError}</span>
          <button type="button" className="ghost" onClick={clearActionError}>Dismiss</button>
        </div>
      ) : null}

      {detail.summaryMarkdown ? <p className="inbox-detail__body">{detail.summaryMarkdown}</p> : null}

      {metrics.length > 0 ? (
        <section className="inbox-detail-section">
          <h3>By the numbers</h3>
          <div className="inbox-metrics">
            {metrics.map(([key, value]) => (
              <span key={key}><small>{key.replaceAll('_', ' ')}</small><strong>{value}</strong></span>
            ))}
          </div>
        </section>
      ) : null}

      {detail.payload.evidence.length > 0 ? (
        <section className="inbox-detail-section">
          <h3>Evidence</h3>
          <div className="inbox-evidence-list">
            {detail.payload.evidence.map((evidence) => <EvidenceRow key={evidence.id} evidence={evidence} />)}
          </div>
        </section>
      ) : null}

      {detail.payload.memoryCandidates.length > 0 ? (
        <section className="inbox-detail-section">
          <h3>Worth remembering</h3>
          <p className="muted">These are proposals. Nothing enters memory until you explicitly approve it.</p>
          {detail.payload.memoryCandidates.map((candidate) => (
            <MemoryCandidateCard
              key={candidate.id}
              candidate={candidate}
              itemID={detail.summary.id}
              fingerprint={detail.summary.fingerprint}
            />
          ))}
        </section>
      ) : null}

      {detail.payload.actions.length > 0 ? (
        <section className="inbox-detail-section">
          <h3>Next</h3>
          <div className="inbox-actions">
            {detail.payload.actions.map((action) => (
              <button
                key={action.id}
                type="button"
                className={action.isPrimary ? 'primary' : 'ghost'}
                onClick={() => void performItemAction(action).catch(reportActionFailure)}
              >
                {actionButtonLabel(action)}
              </button>
            ))}
          </div>
        </section>
      ) : null}

      {detail.payload.verification ? (
        <section className="inbox-verification" aria-label="Verification provenance">
          <strong>{detail.payload.verification.verdict}</strong>
          <span>{detail.payload.verification.reason ?? 'No verifier note.'}</span>
          <span>{detail.summary.modelProvenance}</span>
        </section>
      ) : null}

      <InboxDispositionControls row={row} />
      <InboxThread fingerprint={detail.summary.fingerprint} />
      <FounderPlans />
    </div>
  );
}

export function InboxSurface() {
  const rows = useInboxStore((state) => state.rows);
  const openCount = useInboxStore((state) => state.openCount);
  const activeUnreadCount = useInboxStore((state) => state.activeUnreadCount);
  const selectedID = useInboxStore((state) => state.selectedID);
  const runs = useInboxStore((state) => state.runs);
  const filter = useInboxStore((state) => state.filter);
  const loading = useInboxStore((state) => state.loading);
  const detailLoading = useInboxStore((state) => state.detailLoading);
  const error = useInboxStore((state) => state.error);
  const busy = useInboxStore((state) => state.busy);
  const load = useInboxStore((state) => state.load);
  const loadTelemetry = useInboxStore((state) => state.loadTelemetry);
  const loadPlans = useInboxStore((state) => state.loadPlans);
  const setFilter = useInboxStore((state) => state.setFilter);
  const select = useInboxStore((state) => state.select);
  const markAllRead = useInboxStore((state) => state.markAllRead);
  const setRoute = useShellStore((state) => state.setRoute);
  const routeHash = useShellStore((state) => state.routeHash);
  const routeRevision = useShellStore((state) => state.routeRevision);
  const bridgeReady = useShellStore((state) => state.bridgeReady);

  useLaneLoad(load);
  useEffect(() => {
    void loadTelemetry();
    void loadPlans();
  }, [loadPlans, loadTelemetry]);
  useEffect(() => {
    const routeSelection = inboxSelectionFromHash(routeHash);
    if (routeSelection) void select(routeSelection.itemID);
  }, [bridgeReady, routeHash, routeRevision, select]);

  const selected = selectedID ? rows.find((row) => row.item.summary.id === selectedID) : undefined;
  const latestRun = runs[0];
  const attentionCount = rows.filter((row) =>
    (row.item.summary.state === 'new' || row.item.summary.state === 'updated')
    && row.item.summary.priority <= 2
    && row.presentation.archivedAt === undefined
  ).length;
  const sections = inboxListSections(rows, filter);
  const renderRow = (row: AIInboxPresentationRow) => (
    <InboxListRow
      key={row.item.summary.id}
      item={row.item.summary}
      selected={selectedID === row.item.summary.id}
      unread={row.presentation.readAt === undefined
        && (row.item.summary.state === 'new' || row.item.summary.state === 'updated')}
      onSelect={() => void select(row.item.summary.id)}
    />
  );

  return (
    <section className="inbox-surface" aria-labelledby="inbox-heading" data-testid="inbox-root">
      <aside className="inbox-list-pane" aria-label="AI Inbox items">
        <header className="inbox-header">
          <div className="inbox-kicker-row">
            <span className="inbox-kicker">Inbox</span>
            <span aria-hidden="true">✦</span>
          </div>
          <h2 id="inbox-heading">{openCount > 0 ? `${openCount} open item${openCount === 1 ? '' : 's'}` : 'All caught up'}</h2>
          <p>
            {latestRun
              ? `Last checked ${relativeTime(latestRun.startedAt)}${latestRun.costUSD > 0 ? ` · $${latestRun.costUSD.toFixed(3)}` : ' · no spend'}`
              : 'Waiting for the first analysis.'}
          </p>
          {attentionCount > 0 ? <span className="inbox-attention-pill">{attentionCount} need attention</span> : null}
          {activeUnreadCount > 0 ? (
            <button
              type="button"
              className="inbox-mark-all-read ghost"
              disabled={busy['presentation:mark-all-read'] ?? false}
              onClick={() => void markAllRead()}
            >
              Mark all read
            </button>
          ) : null}
        </header>
        <div className="inbox-filter-rail" role="tablist" aria-label="Inbox filters">
          {FILTERS.map((entry) => (
            <button
              key={entry.id}
              type="button"
              role="tab"
              aria-selected={filter === entry.id}
              className={filter === entry.id ? 'active' : ''}
              onClick={() => setFilter(entry.id)}
            >
              {entry.label}
            </button>
          ))}
        </div>
        {error ? (
          <div className="inbox-list-alert" role="alert">
            <span>{error}</span>
            <button type="button" className="ghost" onClick={() => void load()}>Retry</button>
          </div>
        ) : null}
        <div className="inbox-list" aria-busy={loading}>
          {loading && rows.length === 0 ? <p className="muted" role="status">Reading your inbox…</p> : null}
          {!loading && rows.length === 0 ? (
            <div className="inbox-empty">
              <strong>{filter === 'archived' ? 'Nothing archived' : 'Nothing needs you here'}</strong>
              <p>
                {filter === 'active'
                  ? 'OpenBurnBar will put evidence-backed findings here when something needs a decision.'
                  : 'Change the filter or wait for the next analysis.'}
              </p>
              {filter === 'active' && runs.length === 0 ? (
                <button type="button" className="ghost" onClick={() => setRoute('settings')}>Open Inbox settings</button>
              ) : null}
            </div>
          ) : null}
          {sections.map((section) => (
            <section
              key={section.id}
              className={`inbox-list-section inbox-list-section--${section.id}`}
              aria-labelledby={`inbox-list-section-${section.id}`}
            >
              <div className="inbox-list-section__heading">
                <h3 id={`inbox-list-section-${section.id}`}>{section.label}</h3>
                <span aria-label={`${section.rows.length} ${section.label.toLowerCase()} item${section.rows.length === 1 ? '' : 's'}`}>
                  {section.rows.length}
                </span>
              </div>
              {section.rows.map(renderRow)}
            </section>
          ))}
        </div>
      </aside>
      <main className="inbox-detail-pane" aria-live="polite">
        {detailLoading && !selected ? <p className="muted" role="status">Opening item…</p> : null}
        {selected ? <InboxDetail row={selected} /> : (
          <div className="inbox-detail-empty">
            <span aria-hidden="true">✦</span>
            <h2>Select an inbox item</h2>
            <p>Read the claim, inspect its evidence, discuss it, and decide what becomes a plan.</p>
          </div>
        )}
      </main>
    </section>
  );
}
