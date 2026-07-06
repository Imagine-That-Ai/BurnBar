import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type { MemoryBoundary } from '../../tauriBridge.js';
import '../system/system.css';
import './memory.css';

type MemoryReviewStatus = 'pending' | 'approved' | 'rejected';

type MemoryReviewItem = {
  id: string;
  body: string;
  kind: string;
  confidence: number;
  sourceLabel: string;
  status: MemoryReviewStatus;
  canApprove: boolean;
};

type InboxFilter = 'all' | 'pending' | 'approved' | 'rejected';

const INBOX_FILTERS: { key: InboxFilter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'pending', label: 'Pending' },
  { key: 'approved', label: 'Approved' },
  { key: 'rejected', label: 'Rejected' }
];

const REVIEW_STATUS_STORAGE_KEY = 'openburnbar.linux.memoryReviewStatus.v1';

const FIXTURE_REVIEW_SEED: MemoryReviewItem[] = [
  {
    id: 'mem-review-1',
    body: 'Prefer Rust for daemon IPC handlers; keep Swift types as the contract source of truth.',
    kind: 'preference',
    confidence: 0.86,
    sourceLabel: 'Chat · Hermes · 2h ago',
    status: 'pending',
    canApprove: true
  },
  {
    id: 'mem-review-2',
    body: 'BurnBar Linux shell uses AF_UNIX to the packaged daemon; never mock live quota data in routes.',
    kind: 'fact',
    confidence: 0.92,
    sourceLabel: 'Chat · Codex · Yesterday',
    status: 'pending',
    canApprove: true
  },
  {
    id: 'mem-review-3',
    body: 'Design tokens live in tokens.css; lane CSS stays component-local on Linux.',
    kind: 'fact',
    confidence: 0.78,
    sourceLabel: 'Chat · Hermes · 3d ago',
    status: 'approved',
    canApprove: true
  }
];

function readStoredStatuses(): Record<string, MemoryReviewStatus> {
  try {
    const raw = localStorage.getItem(REVIEW_STATUS_STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as Record<string, MemoryReviewStatus>;
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

function writeStoredStatus(id: string, status: MemoryReviewStatus): void {
  const next = { ...readStoredStatuses(), [id]: status };
  localStorage.setItem(REVIEW_STATUS_STORAGE_KEY, JSON.stringify(next));
}

function applyStoredStatuses(items: MemoryReviewItem[]): MemoryReviewItem[] {
  const stored = readStoredStatuses();
  return items.map((item) => {
    const override = stored[item.id];
    return override ? { ...item, status: override } : item;
  });
}

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
    default:
      return {
        title: 'No memory items yet',
        body: 'Extracted memories from chats will appear in this inbox once the daemon exposes review rows on Linux.'
      };
  }
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
  onRevoke
}: {
  item: MemoryReviewItem;
  onApprove: () => void;
  onReject: () => void;
  onRevoke: () => void;
}) {
  const pending = item.status === 'pending';
  const approved = item.status === 'approved';

  const handleReject = () => {
    const ok = window.confirm("Reject this memory? It won't be remembered or used in any chat.");
    if (ok) onReject();
  };

  const handleRevoke = () => {
    const ok = window.confirm('Revoke this approved memory? It will return to pending review.');
    if (ok) onRevoke();
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
            <button type="button" className="ghost memory-review-reject" onClick={handleRevoke}>
              Revoke
            </button>
          </>
        ) : pending ? (
          <>
            <button type="button" className="ghost memory-review-reject" onClick={handleReject}>
              Reject
            </button>
            <button type="button" className="primary" disabled={!item.canApprove} onClick={onApprove}>
              Approve
            </button>
          </>
        ) : (
          <span className="muted">Rejected</span>
        )}
      </div>
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

export function MemorySurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();
  const memory = useSystemStore((s) => s.memory);
  const loading = useSystemStore((s) => s.loading);
  const error = useSystemStore((s) => s.error);
  const loadMemory = useSystemStore((s) => s.loadMemory);

  const [inboxFilter, setInboxFilter] = useState<InboxFilter>('pending');
  const [reviewItems, setReviewItems] = useState<MemoryReviewItem[]>([]);
  const [inboxError, setInboxError] = useState<string | null>(null);
  const [inboxLoading, setInboxLoading] = useState(false);

  useLaneLoad(loadMemory);

  const loadInbox = useCallback(async () => {
    if (fixtureMode) {
      setInboxLoading(true);
      setInboxError(null);
      const boundariesEmpty = memory !== null && memory.length === 0;
      setReviewItems(boundariesEmpty ? [] : applyStoredStatuses(FIXTURE_REVIEW_SEED));
      setInboxLoading(false);
      return;
    }
    if (!bridge) {
      setReviewItems([]);
      setInboxError(null);
      return;
    }
    setInboxLoading(true);
    setInboxError(null);
    try {
      // Boundaries load via systemStore; inbox rows await dedicated daemon review RPC on Linux.
      setReviewItems([]);
    } catch (e) {
      setInboxError(e instanceof Error ? e.message : 'Failed to load memory review inbox');
      setReviewItems([]);
    } finally {
      setInboxLoading(false);
    }
  }, [bridge, fixtureMode, memory]);
  useEffect(() => {
    void loadInbox();
  }, [loadInbox]);

  const setItemStatus = useCallback((id: string, status: MemoryReviewStatus) => {
    if (fixtureMode) {
      writeStoredStatus(id, status);
    }
    setReviewItems((prev) => prev.map((item) => (item.id === id ? { ...item, status } : item)));
  }, [fixtureMode]);

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

  if (!surfacePopulated && !inboxLoading && !fixtureMode && boundaries.length === 0 && reviewItems.length === 0) {
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
              onApprove={() => setItemStatus(item.id, 'approved')}
              onReject={() => setItemStatus(item.id, 'rejected')}
              onRevoke={() => setItemStatus(item.id, 'pending')}
            />
          ))}
        </div>
      )}

      <RecallBoundariesSection boundaries={boundaries} sourceLabel={sourceLabel} />
    </div>
  );
}