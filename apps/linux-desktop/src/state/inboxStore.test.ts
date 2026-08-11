// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  AIInboxPlan,
  AIInboxPresentationListRequest,
  AIInboxPresentationRow,
  LinuxShellBridge
} from '../tauriBridge.js';
import { useInboxStore, type InboxFilter } from './inboxStore.js';
import { useShellStore } from './shellStore.js';

function row(overrides: Partial<AIInboxPresentationRow['presentation']> = {}): AIInboxPresentationRow {
  const seenAt = '2026-08-10T12:00:00.000Z';
  return {
    item: {
      summary: {
        id: 'inbox-1',
        fingerprint: 'stuck_pr:burnbar:2172',
        kind: 'stuck_pr',
        priority: 1,
        state: 'updated',
        title: 'PR #2172 needs approval',
        projectID: 'burnbar',
        projectName: 'OpenBurnBar',
        occurrenceCount: 2,
        firstSeenAt: seenAt,
        lastSeenAt: seenAt,
        modelProvenance: 'local-rules',
        hasMemoryCandidates: false
      },
      summaryMarkdown: 'One approval remains.',
      payload: {
        version: 1,
        evidence: [],
        memoryCandidates: [],
        actions: [],
        metrics: {}
      },
      tickID: 'tick-1'
    },
    presentation: overrides
  };
}

function plan(stepOverrides: Partial<AIInboxPlan['steps'][number]> = {}): AIInboxPlan {
  const timestamp = '2026-08-10T12:00:00.000Z';
  return {
    id: 'plan-1',
    title: 'Ship Linux parity',
    horizon: 'week',
    pack: 'engOps',
    status: 'active',
    summaryMarkdown: 'Close the remaining gaps.',
    createdAt: timestamp,
    updatedAt: timestamp,
    steps: [{
      id: 'step-1',
      planID: 'plan-1',
      ordinal: 1,
      title: 'Close the authority gap',
      bodyMarkdown: 'Use daemon truth.',
      status: 'accepted',
      evidenceIDs: [],
      createdAt: timestamp,
      updatedAt: timestamp,
      ...stepOverrides
    }]
  };
}

function resetStores(): void {
  useShellStore.setState({
    bridge: null,
    bridgeReady: true,
    fixtureMode: false
  });
  useInboxStore.setState({
    rows: [],
    openCount: 0,
    activeUnreadCount: 0,
    selectedID: null,
    threads: {},
    plans: [],
    runs: [],
    filter: 'active',
    loading: false,
    detailLoading: false,
    plansLoading: false,
    error: null,
    actionError: null,
    refusalReason: null,
    busy: {}
  });
  location.hash = '#/inbox';
}

describe('inboxStore durable presentation state', () => {
  beforeEach(resetStores);
  afterEach(() => {
    resetStores();
    vi.restoreAllMocks();
  });

  it.each([
    ['active', {
      states: ['new', 'updated'],
      isArchived: false,
      isSnoozed: false,
      limit: 200
    }],
    ['attention', {
      states: ['new', 'updated'],
      priorities: [1, 2],
      isArchived: false,
      isSnoozed: false,
      limit: 200
    }],
    ['resolved', {
      states: ['resolved', 'expired'],
      limit: 200
    }],
    ['archived', {
      states: ['new', 'updated'],
      isArchived: true,
      limit: 200
    }]
  ] satisfies Array<[InboxFilter, AIInboxPresentationListRequest]>)(
    'loads the %s filter from daemon presentation truth',
    async (filter, expectedRequest) => {
      const inboxPresentationList = vi.fn(async () => ({
        rows: [],
        openCount: 4,
        activeUnreadCount: 2
      }));
      useShellStore.setState({
        bridge: { inboxPresentationList } as unknown as LinuxShellBridge
      });
      useInboxStore.setState({ filter });

      await useInboxStore.getState().load();

      expect(inboxPresentationList).toHaveBeenCalledWith(expectedRequest);
      expect(useInboxStore.getState().openCount).toBe(4);
      expect(useInboxStore.getState().activeUnreadCount).toBe(2);
    }
  );

  it('marks a selected unread row through the daemon and consumes readback', async () => {
    const unread = row();
    const read = row({ readAt: '2026-08-10T12:01:00.000Z' });
    const inboxPresentationGet = vi.fn(async () => ({ row: unread }));
    const inboxPresentationMutate = vi.fn(async () => ({ row: read }));
    const inboxPresentationList = vi.fn(async () => ({
      rows: [read],
      openCount: 1,
      activeUnreadCount: 0
    }));
    const inboxThreadGet = vi.fn(async () => ({ }));
    useShellStore.setState({
      bridge: {
        inboxPresentationGet,
        inboxPresentationMutate,
        inboxPresentationList,
        inboxThreadGet
      } as unknown as LinuxShellBridge
    });
    useInboxStore.setState({ rows: [unread], activeUnreadCount: 1 });

    await useInboxStore.getState().select('inbox-1');

    expect(inboxPresentationMutate).toHaveBeenCalledWith({
      itemID: 'inbox-1',
      action: 'mark_read'
    });
    expect(useInboxStore.getState().rows[0]?.presentation.readAt).toBe(read.presentation.readAt);
    expect(useInboxStore.getState().activeUnreadCount).toBe(0);
  });

  it('archives with daemon authority and removes the row after filtered reload', async () => {
    const original = row({ readAt: '2026-08-10T12:01:00.000Z' });
    const archived = row({
      readAt: '2026-08-10T12:01:00.000Z',
      archivedAt: '2026-08-10T12:02:00.000Z'
    });
    const inboxPresentationMutate = vi.fn(async () => ({ row: archived }));
    const inboxPresentationList = vi.fn(async () => ({
      rows: [],
      openCount: 1,
      activeUnreadCount: 0
    }));
    useShellStore.setState({
      bridge: {
        inboxPresentationMutate,
        inboxPresentationList
      } as unknown as LinuxShellBridge
    });
    useInboxStore.setState({ rows: [original], selectedID: 'inbox-1' });

    await useInboxStore.getState().setArchived('inbox-1', true);

    expect(inboxPresentationMutate).toHaveBeenCalledWith({
      itemID: 'inbox-1',
      action: 'archive'
    });
    expect(useInboxStore.getState().rows).toEqual([]);
    expect(useInboxStore.getState().selectedID).toBeNull();
  });

  it('keeps prior truth visible when a presentation mutation fails', async () => {
    const original = row({ readAt: '2026-08-10T12:01:00.000Z' });
    const inboxPresentationMutate = vi.fn().mockRejectedValue(new Error('database busy'));
    useShellStore.setState({
      bridge: { inboxPresentationMutate } as unknown as LinuxShellBridge
    });
    useInboxStore.setState({ rows: [original] });

    const updated = await useInboxStore.getState().setFeedback('inbox-1', 'useful');

    expect(updated).toBe(false);
    expect(useInboxStore.getState().rows).toEqual([original]);
    expect(useInboxStore.getState().actionError).toMatch(/database busy/i);
  });

  it('marks every open item read and uses the authoritative unread count', async () => {
    const unread = row();
    const read = row({ readAt: '2026-08-10T12:03:00.000Z' });
    const inboxPresentationMarkAllRead = vi.fn(async () => ({
      updatedCount: 1,
      readAt: '2026-08-10T12:03:00.000Z',
      activeUnreadCount: 0
    }));
    const inboxPresentationList = vi.fn(async () => ({
      rows: [read],
      openCount: 1,
      activeUnreadCount: 0
    }));
    const inboxThreadGet = vi.fn(async () => ({}));
    useShellStore.setState({
      bridge: {
        inboxPresentationMarkAllRead,
        inboxPresentationList,
        inboxThreadGet
      } as unknown as LinuxShellBridge
    });
    useInboxStore.setState({ rows: [unread], activeUnreadCount: 1 });

    await useInboxStore.getState().markAllRead();

    expect(inboxPresentationMarkAllRead).toHaveBeenCalledOnce();
    expect(useInboxStore.getState().activeUnreadCount).toBe(0);
    expect(useInboxStore.getState().rows[0]?.presentation.readAt).toBe(read.presentation.readAt);
  });

  it('approves one canonical memory candidate by identity only', async () => {
    const inboxMemoryCandidateApprove = vi.fn(async () => ({
      memoryID: 'mem-1',
      provenance: 'ai-inbox:item:stuck_pr:burnbar:2172:candidate:candidate-1',
      quarantineAuditHash: 'quarantine-hash',
      approvalAuditHash: 'approval-hash'
    }));
    useShellStore.setState({
      bridge: { inboxMemoryCandidateApprove } as unknown as LinuxShellBridge
    });

    const approved = await useInboxStore.getState().approveMemoryCandidate(
      'inbox-1',
      'stuck_pr:burnbar:2172',
      'candidate-1'
    );

    expect(approved).toBe(true);
    expect(inboxMemoryCandidateApprove).toHaveBeenCalledWith({
      itemID: 'inbox-1',
      fingerprint: 'stuck_pr:burnbar:2172',
      candidateID: 'candidate-1'
    });
    expect(useInboxStore.getState().busy['memory:inbox-1:candidate-1']).toBe(false);
  });

  it('consumes daemon readback when remembering a Founder Plan step', async () => {
    const original = plan();
    const updated = plan({ memoryID: 'mem-plan-1' });
    const inboxPlansRememberStep = vi.fn(async () => ({
      plan: updated,
      step: updated.steps[0]!,
      memory: {
        memoryID: 'mem-plan-1',
        provenance: 'ai-inbox:plan:plan-1:step:step-1',
        quarantineAuditHash: 'quarantine-hash',
        approvalAuditHash: 'approval-hash'
      }
    }));
    useShellStore.setState({
      bridge: { inboxPlansRememberStep } as unknown as LinuxShellBridge
    });
    useInboxStore.setState({ plans: [original] });

    const remembered = await useInboxStore.getState().rememberStep('step-1');

    expect(remembered).toBe(true);
    expect(inboxPlansRememberStep).toHaveBeenCalledWith({ stepID: 'step-1' });
    expect(useInboxStore.getState().plans[0]?.steps[0]?.memoryID).toBe('mem-plan-1');
  });

  it('creates and binds a follow-up using selected daemon project attribution', async () => {
    const original = plan();
    const updated = plan({ followupID: 'followup-inbox-step-1' });
    const inboxPlansCreateFollowup = vi.fn(async () => ({
      plan: updated,
      step: updated.steps[0]!,
      followupID: 'followup-inbox-step-1',
      projectSlug: 'burnbar',
      title: 'Close the authority gap',
      dueAt: '2026-08-11T12:00:00.000Z'
    }));
    useShellStore.setState({
      bridge: { inboxPlansCreateFollowup } as unknown as LinuxShellBridge
    });
    useInboxStore.setState({
      rows: [row()],
      selectedID: 'inbox-1',
      plans: [original]
    });

    const created = await useInboxStore.getState().createFollowup('step-1');

    expect(created).toBe(true);
    expect(inboxPlansCreateFollowup).toHaveBeenCalledWith({
      stepID: 'step-1',
      projectSlug: 'burnbar'
    });
    expect(useInboxStore.getState().plans[0]?.steps[0]?.followupID).toBe(
      'followup-inbox-step-1'
    );
  });
});
