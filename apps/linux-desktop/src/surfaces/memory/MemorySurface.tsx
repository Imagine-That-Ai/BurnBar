import { useMemo, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useMemoryStore } from '../../state/memoryStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type {
  MemoryBoundary,
  MemoryReviewInbox,
  MemoryReviewItem,
  MemoryReviewStatus
} from '../../tauriBridge.js';
import '../system/system.css';
import './memory.css';

type InboxFilter = 'all' | 'pending' | 'approved' | 'rejected' | 'forgotten';

const INBOX_FILTERS: { key: InboxFilter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'pending', label: 'Pending' },
  { key: 'approved', label: 'Approved' },
  { key: 'rejected', label: 'Rejected' },
  { key: 'forgotten', label: 'Forgotten' }
];

function countForFilter(items: MemoryReviewItem[], filter: InboxFilter): number {
  if (filter === 'all') return items.length;
  return items.filter((item) => item.status === filter).length;
}

function filterItems(items: MemoryReviewItem[], filter: InboxFilter): MemoryReviewItem[] {
  if (filter === 'all') return items;
  return items.filter((item) => item.status === filter);
}

function emptyInboxCopy(filter: InboxFilter): { title: string; body: string } {
  switch (filter) {
    case 'pending':
      return {
        title: 'No memory items pending review',
        body: 'When a chat surfaces a durable fact or preference worth remembering, it lands here for your approval.'
      };
    case 'approved':
      return {
        title: 'Nothing approved yet',
        body: 'Memories you approve will appear here. You can revoke any of them at any time.'
      };
    case 'rejected':
      return {
        title: 'No rejected memories',
        body: 'Rejected items stay out of recall. They will not be injected into future chats.'
      };
    case 'forgotten':
      return {
        title: 'No forgotten memories',
        body: 'Forgotten memories keep an audit tombstone but their sealed body is removed from local recall.'
      };
    default:
      return {
        title: 'No memory items yet',
        body: 'Candidates stay quarantined until approval. Reject keeps a durable out-of-recall decision; forget removes the sealed body and leaves only an audit tombstone.'
      };
  }
}

function auditActionLabel(action: string): string {
  switch (action.trim().toLowerCase()) {
    case 'remember':
    case 'approve':
    case 'approved':
      return 'Approved';
    case 'reject':
    case 'rejected':
      return 'Rejected';
    case 'forget':
    case 'forgotten':
      return 'Forgotten';
    default:
      return action.trim() || 'Review event';
  }
}

function boundedAuditText(value: string, fallback: string): string {
  const text = value.trim();
  if (!text) return fallback;
  return text.length > 120 ? `${text.slice(0, 117)}…` : text;
}

function auditTimestamp(at: string): { label: string; dateTime?: string } {
  const date = new Date(at);
  if (!at.trim() || !Number.isFinite(date.getTime())) return { label: 'Time unavailable' };
  return { label: date.toLocaleString(), dateTime: date.toISOString() };
}

function MemorySkeleton() {
  return (
    <div className="system-skeleton" aria-busy="true">
      <div className="system-skeleton-line" />
    </div>
  );
}

function MemoryReviewRow({
  item,
  onApprove,
  onReject,
  onForget,
  pendingDecision,
  decisionError
}: {
  item: MemoryReviewItem;
  onApprove: () => void;
  onReject: () => void;
  onForget: () => void;
  pendingDecision?: boolean;
  decisionError?: string | null;
}) {
  const pending = item.status === 'pending';
  const approved = item.status === 'approved';

  const handleReject = () => {
    const ok = window.confirm("Reject this memory? It won't be remembered or used in any chat.");
    if (ok) onReject();
  };

  const handleRevoke = () => {
    const ok = window.confirm(
      'Permanently forget this memory? It will be deleted from local recall (not returned to pending).'
    );
    if (ok) onForget();
  };

  const confidencePct = Math.round(item.confidence * 100);
  const bodyText = item.body.trim() || '(Memory contents unavailable)';

  return (
    <article className="memory-review-card" data-memory-id={item.id}>
      <div className="memory-review-card-meta">
        <span className="memory-review-kind">{item.kind}</span>
        <span className="memory-review-confidence">{confidencePct}% confidence</span>
      </div>
      <p className="memory-review-body">{bodyText}</p>
      <p className="memory-review-source">Source: {item.sourceLabel}</p>
      <div className="memory-review-actions">
        {approved ? (
          <>
            <span className="memory-review-approved-mark">Approved</span>
            <button
              type="button"
              className="ghost memory-review-reject"
              onClick={handleRevoke}
              disabled={pendingDecision}
              aria-busy={pendingDecision}
            >
              {pendingDecision ? 'Forgetting…' : 'Forget permanently'}
            </button>
          </>
        ) : pending ? (
          <>
            <button
              type="button"
              className="ghost memory-review-reject"
              onClick={handleReject}
              disabled={pendingDecision}
              aria-busy={pendingDecision}
            >
              {pendingDecision ? 'Rejecting...' : 'Reject'}
            </button>
            <button
              type="button"
              className="primary"
              disabled={!item.canApprove || pendingDecision || !item.body.trim()}
              onClick={onApprove}
              title={
                item.body.trim()
                  ? 'Save this body as a durable memory via daemon.memory.remember'
                  : 'Body text required to save as memory'
              }
            >
              {pendingDecision ? 'Saving…' : 'Save as memory'}
            </button>
          </>
        ) : item.status === 'rejected' ? (
          <span className="muted">Rejected</span>
        ) : (
          <span className="muted">Forgotten</span>
        )}
      </div>
      {decisionError ? (
        <p className="memory-inbox-banner" role="alert">
          {decisionError}
        </p>
      ) : null}
    </article>
  );
}

function RecallBoundariesSection({
  boundaries,
  sourceLabel
}: {
  boundaries: MemoryBoundary[];
  sourceLabel: string;
}) {
  if (boundaries.length === 0) {
    return (
      <section className="memory-boundaries-section" aria-labelledby="memory-boundaries-heading">
        <p id="memory-boundaries-heading" className="memory-boundaries-heading">
          <strong>Recall boundaries</strong> — scopes the daemon may read or write for project recall.
        </p>
        <p className="muted memory-boundaries-empty">No memory boundaries configured</p>
      </section>
    );
  }

  return (
    <section className="memory-boundaries-section" aria-labelledby="memory-boundaries-heading">
      <p id="memory-boundaries-heading" className="memory-boundaries-heading">
        <strong>Recall boundaries</strong> — scopes the daemon may read or write for project recall.
      </p>
      <p className="muted data-source">{`Data source: ${sourceLabel}`}</p>
      <table className="table fixture-table">
        <thead>
          <tr>
            <th>ID</th>
            <th>Title</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
          {boundaries.map((m) => (
            <tr key={m.id}>
              <td>{m.id}</td>
              <td>
                <span className="system-scope-chip" data-scope={m.scope}>
                  {m.scope}
                </span>{' '}
                {m.label}
              </td>
              <td>{m.detail}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}

function MemoryAuditSection({ events }: { events: MemoryReviewInbox['auditEvents'] }) {
  return (
    <section className="memory-audit-section" aria-labelledby="memory-audit-heading">
      <div className="memory-audit-header">
        <div>
          <h3 id="memory-audit-heading" className="memory-audit-heading">Audit trail</h3>
          <p className="muted memory-audit-lede">
            Daemon-reported review events. An empty or unavailable timestamp is shown as unavailable; this surface never invents event time.
          </p>
        </div>
        <span className="memory-audit-count" role="status">{events.length} event{events.length === 1 ? '' : 's'}</span>
      </div>
      {events.length === 0 ? (
        <p className="muted memory-audit-empty">No review events have been recorded yet.</p>
      ) : (
        <ol className="memory-audit-list" aria-label="Memory audit events">
          {events.map((event, index) => {
            const timestamp = auditTimestamp(event.at);
            const eventID = boundedAuditText(event.id, `event-${index + 1}`);
            const actor = boundedAuditText(event.actor, 'daemon');
            return (
              <li key={`${event.id}-${index}`} className="memory-audit-row">
                <span className="memory-audit-index" aria-hidden="true">{index + 1}</span>
                <div className="memory-audit-event">
                  <p className="memory-audit-summary">
                    <strong>{auditActionLabel(event.action)}</strong>
                    <span> by {actor}</span>
                  </p>
                  <p className="memory-audit-detail">
                    <time dateTime={timestamp.dateTime}>{timestamp.label}</time>
                    {event.subjectId ? <span> · Subject {boundedAuditText(event.subjectId, 'unavailable')}</span> : null}
                  </p>
                  <code className="memory-audit-id" title={eventID}>Event {eventID}</code>
                </div>
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}

export function MemorySurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();
  const memory = useSystemStore((s) => s.memory);
  const loading = useSystemStore((s) => s.loading);
  const error = useSystemStore((s) => s.error);
  const loadMemory = useSystemStore((s) => s.loadMemory);
  const inbox = useMemoryStore((s) => s.inbox);
  const inboxLoading = useMemoryStore((s) => s.loading);
  const inboxError = useMemoryStore((s) => s.error);
  const decisionById = useMemoryStore((s) => s.decisionById);
  const loadInbox = useMemoryStore((s) => s.loadInbox);
  const decideMemory = useMemoryStore((s) => s.decide);
  const forgetMemory = useMemoryStore((s) => s.forget);

  const [inboxFilter, setInboxFilter] = useState<InboxFilter>('pending');

  useLaneLoad(loadMemory);
  useLaneLoad(loadInbox);

  const reviewItems = inbox?.items ?? [];
  const pendingCount = useMemo(
    () => reviewItems.filter((item) => item.status === 'pending').length,
    [reviewItems]
  );

  const visibleItems = useMemo(
    () => filterItems(reviewItems, inboxFilter),
    [reviewItems, inboxFilter]
  );

  const boundaries = memory ?? [];
  const sourceLabel = fixtureMode ? 'fixture transcript' : 'live daemon memory boundaries';
  const inboxEmptyCopy = emptyInboxCopy(inboxFilter);
  const surfacePopulated = boundaries.length > 0 || reviewItems.length > 0;

  if (loading && memory === null && !fixtureMode) {
    return <MemorySkeleton />;
  }

  const offline = !fixtureMode && !bridge && !loading;
  if (offline) {
    return (
      <OfflineNotice
        status={status}
        summary="Memory review and recall boundaries need the local daemon before they can load."
        fixtureMode={fixtureMode}
      />
    );
  }

  if (error && memory === null && !fixtureMode) {
    return (
      <Banner tone="degraded" role="alert">
        {error}
        <div className="actions">
          <button type="button" className="ghost" onClick={() => void loadMemory()}>
            Retry
          </button>
        </div>
      </Banner>
    );
  }

  if (
    !surfacePopulated &&
    !inboxLoading &&
    !fixtureMode &&
    boundaries.length === 0 &&
    reviewItems.length === 0 &&
    !inboxError &&
    !inbox?.degradedReason
  ) {
    return (
      <div className="memory-surface">
        <header className="memory-inbox-header">
          <p className="memory-inbox-kicker">
            <span className="memory-inbox-kicker-mark" aria-hidden="true" />
            Memory review
          </p>
          <h2 className="memory-inbox-title">Approve what to remember</h2>
          <p className="memory-inbox-lede">
            Memories stay quarantined until you approve them — nothing is used in a chat before you say so.
          </p>
        </header>
        <div className="memory-inbox-empty">
          <p className="memory-inbox-empty-title">No memory items pending review</p>
          <p className="memory-inbox-empty-body">{inboxEmptyCopy.body}</p>
        </div>
        <RecallBoundariesSection boundaries={boundaries} sourceLabel={sourceLabel} />
        <MemoryAuditSection events={inbox?.auditEvents ?? []} />
      </div>
    );
  }

  return (
    <div className="memory-surface">
      <header className="memory-inbox-header">
        <p className="memory-inbox-kicker">
          <span className="memory-inbox-kicker-mark" aria-hidden="true" />
          Memory review
          {pendingCount > 0 ? <span className="memory-inbox-pending-pill">{pendingCount} pending</span> : null}
        </p>
        <h2 className="memory-inbox-title">Approve what to remember</h2>
        <p className="memory-inbox-lede">
          Memories stay quarantined until you approve them — nothing is used in a chat before you say so.
        </p>
      </header>

      <div className="memory-filter-rail" role="group" aria-label="Memory review filter">
        <p className="memory-filter-kicker">Filter</p>
        <div className="memory-filter-scroll">
          {INBOX_FILTERS.map(({ key, label }) => {
            const count = countForFilter(reviewItems, key);
            const isActive = inboxFilter === key;
            return (
              <button
                key={key}
                type="button"
                className={`memory-filter-chip${isActive ? ' memory-filter-chip--active' : ''}`}
                aria-pressed={isActive}
                onClick={() => setInboxFilter(key)}
              >
                <span>{label}</span>
                <span className="memory-filter-chip-count" aria-hidden="true">
                  {count}
                </span>
              </button>
            );
          })}
        </div>
      </div>

      {inboxError ? (
        <div className="memory-inbox-banner" role="alert">
          {inboxError}
        </div>
      ) : null}
      {inbox?.degradedReason ? (
        <div className="memory-inbox-banner" role="alert">
          {inbox.degradedReason}
        </div>
      ) : null}

      {inboxLoading ? (
        <MemorySkeleton />
      ) : visibleItems.length === 0 ? (
        <div className="memory-inbox-empty">
          <p className="memory-inbox-empty-title">{inboxEmptyCopy.title}</p>
          <p className="memory-inbox-empty-body">{inboxEmptyCopy.body}</p>
        </div>
      ) : (
        <div className="memory-inbox-list">
          {visibleItems.map((item) => (
            <MemoryReviewRow
              key={item.id}
              item={item}
              pendingDecision={decisionById[item.id]?.pending}
              decisionError={decisionById[item.id]?.error}
              onApprove={() => void decideMemory(item.id, 'approved')}
              onReject={() => void decideMemory(item.id, 'rejected')}
              onForget={() => void forgetMemory(item.id)}
            />
          ))}
        </div>
      )}

      <RecallBoundariesSection boundaries={boundaries} sourceLabel={sourceLabel} />
      <MemoryAuditSection events={inbox?.auditEvents ?? []} />
    </div>
  );
}
