import { create } from 'zustand';
import { inboxRouteHash } from '../routes.js';
import { useShellStore } from './shellStore.js';
import type {
  AIInboxFeedback,
  AIInboxPlan,
  AIInboxPlanCandidate,
  AIInboxPlanStepStatus,
  AIInboxPresentationListRequest,
  AIInboxPresentationListResponse,
  AIInboxPresentationMutationAction,
  AIInboxPresentationRow,
  AIInboxReplyResponse,
  AIInboxRunTelemetry,
  AIInboxThread,
  LinuxShellBridge
} from '../tauriBridge.js';

export type InboxFilter = 'active' | 'attention' | 'resolved' | 'archived';

type BusyMap = Record<string, boolean>;
type PresentationMutationOptions = {
  snoozedUntil?: string;
  feedback?: AIInboxFeedback;
};

export type InboxState = {
  rows: AIInboxPresentationRow[];
  openCount: number;
  activeUnreadCount: number;
  selectedID: string | null;
  threads: Record<string, AIInboxThread | null>;
  plans: AIInboxPlan[];
  runs: AIInboxRunTelemetry[];
  filter: InboxFilter;
  loading: boolean;
  detailLoading: boolean;
  plansLoading: boolean;
  error: string | null;
  actionError: string | null;
  refusalReason: string | null;
  busy: BusyMap;
  load(): Promise<void>;
  loadTelemetry(): Promise<void>;
  loadPlans(): Promise<void>;
  setFilter(filter: InboxFilter): void;
  select(id: string | null): Promise<void>;
  sendReply(fingerprint: string, bodyMarkdown: string): Promise<AIInboxReplyResponse | null>;
  acceptCandidate(candidate: AIInboxPlanCandidate, pack?: 'engOps' | 'productStrategy'): Promise<boolean>;
  updateStep(
    stepID: string,
    status?: AIInboxPlanStepStatus,
    missionID?: string,
    followupID?: string
  ): Promise<boolean>;
  gradeStep(stepID: string, grade: number, noteMarkdown?: string): Promise<boolean>;
  promoteStep(plan: AIInboxPlan, stepID: string): Promise<boolean>;
  approveMemoryCandidate(
    itemID: string,
    fingerprint: string,
    candidateID: string
  ): Promise<boolean>;
  rememberStep(stepID: string): Promise<boolean>;
  createFollowup(stepID: string): Promise<boolean>;
  mutatePresentation(
    itemID: string,
    action: AIInboxPresentationMutationAction,
    options?: PresentationMutationOptions
  ): Promise<boolean>;
  toggleRead(itemID: string): Promise<boolean>;
  setArchived(itemID: string, archived: boolean): Promise<boolean>;
  setSnooze(itemID: string, until?: string): Promise<boolean>;
  setFeedback(itemID: string, feedback?: AIInboxFeedback): Promise<boolean>;
  markAllRead(): Promise<boolean>;
  reportActionError(message: string): void;
  clearActionError(): void;
};

function inboxBridge(): LinuxShellBridge | null {
  return useShellStore.getState().bridge;
}

function filterRequest(filter: InboxFilter): AIInboxPresentationListRequest {
  if (filter === 'resolved') {
    return { states: ['resolved', 'expired'], limit: 200 };
  }
  if (filter === 'archived') {
    return { states: ['new', 'updated'], isArchived: true, limit: 200 };
  }
  return {
    states: ['new', 'updated'],
    priorities: filter === 'attention' ? [1, 2] : undefined,
    isArchived: false,
    isSnoozed: false,
    limit: 200
  };
}

function replacePlan(plans: AIInboxPlan[], updated: AIInboxPlan): AIInboxPlan[] {
  const index = plans.findIndex((plan) => plan.id === updated.id);
  if (index < 0) return [...plans, updated];
  return plans.map((plan) => (plan.id === updated.id ? updated : plan));
}

function fixtureData(): {
  list: AIInboxPresentationListResponse;
  thread: AIInboxThread;
  plans: AIInboxPlan[];
  runs: AIInboxRunTelemetry[];
} {
  const now = new Date();
  const earlier = new Date(now.getTime() - 38 * 60_000).toISOString();
  const firstSeen = new Date(now.getTime() - 4 * 60 * 60_000).toISOString();
  const summary: AIInboxPresentationRow['item']['summary'] = {
    id: 'fixture-inbox-1',
    fingerprint: 'fixture:stuck-pr:2172',
    kind: 'stuck_pr',
    priority: 1,
    state: 'updated',
    title: 'PR #2172 is waiting on one approval',
    projectID: 'burnbar',
    projectName: 'OpenBurnBar',
    occurrenceCount: 3,
    firstSeenAt: firstSeen,
    lastSeenAt: earlier,
    modelProvenance: 'local-rules+lens:v1',
    hasMemoryCandidates: true
  };
  const detail: AIInboxPresentationRow['item'] = {
    summary,
    summaryMarkdown:
      'The release candidate is green, but the PR is still open. The next move is to get the required independent approval; CI cannot substitute for it.',
    tickID: 'fixture-tick-1',
    payload: {
      version: 1,
      evidence: [
        {
          id: 'pr:openburnbar#2172',
          kind: 'pull_request',
          label: 'PR #2172',
          detail: 'Open · review required',
          url: 'https://github.com/example/openburnbar/pull/2172',
          occurredAt: earlier
        }
      ],
      memoryCandidates: [
        {
          id: 'fixture-memory-1',
          text: 'Release readiness requires a concrete merge commit, not only green checks.',
          kind: 'release-rule',
          confidence: 0.98,
          citationConversationIDs: []
        }
      ],
      actions: [
        {
          id: 'fixture-action-1',
          kind: 'open_url',
          title: 'Open PR',
          value: 'https://github.com/example/openburnbar/pull/2172',
          isPrimary: true
        }
      ],
      metrics: { blocked_minutes: '228', required_approvals: '1' },
      verification: {
        verdict: 'deterministic',
        reason: 'GitHub still reports the pull request as open.',
        checkedAt: earlier
      }
    }
  };
  const candidate: AIInboxPlanCandidate = {
    title: 'Close the approval gate',
    bodyMarkdown: 'Ask the named independent reviewer to approve PR #2172, then verify the merge commit.',
    horizon: 'week',
    evidenceIDs: ['pr:openburnbar#2172']
  };
  const thread: AIInboxThread = {
    fingerprint: summary.fingerprint,
    itemID: summary.id,
    createdAt: earlier,
    updatedAt: earlier,
    turnCount: 1,
    totalCostUSD: 0,
    messages: [
      {
        id: 'fixture-thread-message-1',
        fingerprint: summary.fingerprint,
        role: 'assistant',
        bodyMarkdown: 'One bottleneck owns this cycle: the missing independent approval.',
        planCandidates: [candidate],
        modelProvenance: 'local-rules+lens:v1',
        costUSD: 0,
        createdAt: earlier
      }
    ]
  };
  const plan: AIInboxPlan = {
    id: 'fixture-plan-1',
    title: 'Ship Linux parity',
    horizon: 'week',
    pack: 'engOps',
    status: 'active',
    summaryMarkdown: 'Close the remaining exact-candidate gates.',
    createdAt: firstSeen,
    updatedAt: earlier,
    originFingerprint: summary.fingerprint,
    steps: [
      {
        id: 'fixture-step-1',
        planID: 'fixture-plan-1',
        ordinal: 1,
        title: 'Close the approval gate',
        bodyMarkdown: candidate.bodyMarkdown,
        status: 'accepted',
        evidenceIDs: candidate.evidenceIDs,
        inboxFingerprint: summary.fingerprint,
        createdAt: earlier,
        updatedAt: earlier
      }
    ]
  };
  return {
    list: {
      rows: [{ item: detail, presentation: {} }],
      openCount: 1,
      activeUnreadCount: 1
    },
    thread,
    plans: [plan],
    runs: [
      {
        tickID: 'fixture-tick-1',
        startedAt: earlier,
        finishedAt: earlier,
        gateResult: 'local_changed',
        egressMode: 'off',
        llmCalls: 0,
        inputTokens: 0,
        outputTokens: 0,
        costUSD: 0,
        itemsNew: 1,
        itemsUpdated: 0,
        itemsResolved: 0
      }
    ]
  };
}

function errorMessage(cause: unknown, fallback: string): string {
  return cause instanceof Error ? cause.message : fallback;
}

function replacePresentationRow(
  rows: AIInboxPresentationRow[],
  replacement: AIInboxPresentationRow
): AIInboxPresentationRow[] {
  const index = rows.findIndex((row) => row.item.summary.id === replacement.item.summary.id);
  if (index < 0) return [...rows, replacement];
  return rows.map((row, rowIndex) => rowIndex === index ? replacement : row);
}

function isOpen(row: AIInboxPresentationRow): boolean {
  return row.item.summary.state === 'new' || row.item.summary.state === 'updated';
}

function isSnoozed(row: AIInboxPresentationRow, now = Date.now()): boolean {
  const until = row.presentation.snoozedUntil;
  return until !== undefined && Date.parse(until) > now;
}

function activeUnreadCount(rows: AIInboxPresentationRow[]): number {
  return rows.filter((row) =>
    isOpen(row)
    && row.presentation.readAt === undefined
    && row.presentation.archivedAt === undefined
    && !isSnoozed(row)
  ).length;
}

function fixtureMutation(
  row: AIInboxPresentationRow,
  action: AIInboxPresentationMutationAction,
  options: PresentationMutationOptions
): AIInboxPresentationRow {
  const now = new Date().toISOString();
  const presentation = { ...row.presentation, updatedAt: now };
  if (action === 'mark_read') presentation.readAt = presentation.readAt ?? now;
  if (action === 'mark_unread') delete presentation.readAt;
  if (action === 'archive') {
    presentation.archivedAt = now;
    presentation.readAt = presentation.readAt ?? now;
  }
  if (action === 'unarchive') delete presentation.archivedAt;
  if (action === 'snooze') {
    presentation.snoozedUntil = options.snoozedUntil;
    presentation.readAt = presentation.readAt ?? now;
  }
  if (action === 'clear_snooze') delete presentation.snoozedUntil;
  if (action === 'set_feedback') presentation.feedback = options.feedback;
  if (action === 'clear_feedback') delete presentation.feedback;
  return { ...row, presentation };
}

export const useInboxStore = create<InboxState>()((set, get) => ({
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
  busy: {},

  async load() {
    const shell = useShellStore.getState();
    if (shell.fixtureMode) {
      const fixture = fixtureData();
      const selectedID = get().selectedID ?? fixture.list.rows[0]?.item.summary.id ?? null;
      set({
        rows: fixture.list.rows,
        openCount: fixture.list.openCount,
        activeUnreadCount: fixture.list.activeUnreadCount,
        threads: { [fixture.thread.fingerprint]: fixture.thread },
        plans: fixture.plans,
        runs: fixture.runs,
        selectedID,
        loading: false,
        error: null
      });
      if (selectedID) await get().select(selectedID);
      return;
    }
    const bridge = inboxBridge();
    if (!bridge?.inboxPresentationList) {
      set({ loading: false, error: 'The installed Linux shell does not expose the AI Inbox bridge yet.' });
      return;
    }
    set({ loading: true, error: null });
    try {
      const response = await bridge.inboxPresentationList(filterRequest(get().filter));
      const selectedID = get().selectedID && response.rows.some((row) => row.item.summary.id === get().selectedID)
        ? get().selectedID
        : response.rows[0]?.item.summary.id ?? null;
      set({
        rows: response.rows,
        openCount: response.openCount,
        activeUnreadCount: response.activeUnreadCount,
        selectedID,
        loading: false,
        error: null
      });
      if (selectedID) await get().select(selectedID);
    } catch (cause) {
      set({ loading: false, error: errorMessage(cause, 'Could not load the AI Inbox.') });
    }
  },

  async loadTelemetry() {
    if (useShellStore.getState().fixtureMode) return;
    const bridge = inboxBridge();
    if (!bridge?.inboxRunsRecent) return;
    try {
      const response = await bridge.inboxRunsRecent(20);
      set({ runs: response.runs });
    } catch {
      // Telemetry supports the trust story but never blanks an otherwise usable inbox.
    }
  },

  async loadPlans() {
    if (useShellStore.getState().fixtureMode) return;
    const bridge = inboxBridge();
    if (!bridge?.inboxPlansList) return;
    set({ plansLoading: true });
    try {
      const response = await bridge.inboxPlansList({ statuses: ['active', 'paused'], limit: 200 });
      set({ plans: response.plans, plansLoading: false });
    } catch (cause) {
      set({ plansLoading: false, actionError: errorMessage(cause, 'Could not load Founder Plans.') });
    }
  },

  setFilter(filter) {
    set({ filter, selectedID: null, error: null });
    void get().load();
  },

  async select(id) {
    set({ selectedID: id, refusalReason: null });
    if (typeof window !== 'undefined') {
      const hash = inboxRouteHash(id);
      if (location.hash !== hash) history.replaceState(null, '', hash);
    }
    if (!id) return;
    const fixtureMode = useShellStore.getState().fixtureMode;
    let row = get().rows.find((entry) => entry.item.summary.id === id);
    if (fixtureMode) {
      if (row?.presentation.readAt === undefined) {
        await get().mutatePresentation(id, 'mark_read');
      }
      return;
    }
    const bridge = inboxBridge();
    if (!bridge?.inboxPresentationGet) return;
    set({ detailLoading: true, actionError: null });
    try {
      row ??= (await bridge.inboxPresentationGet(id)).row;
      if (!row) throw new Error('This inbox item no longer exists.');
      set((state) => ({ rows: replacePresentationRow(state.rows, row!) }));
      if (row.presentation.readAt === undefined && isOpen(row)) {
        await get().mutatePresentation(id, 'mark_read');
        row = get().rows.find((entry) => entry.item.summary.id === id) ?? row;
      }
      const fingerprint = row.item.summary.fingerprint;
      const thread = (await bridge.inboxThreadGet(fingerprint)).thread ?? null;
      set((state) => ({
        threads: { ...state.threads, [fingerprint]: thread },
        detailLoading: false
      }));
    } catch (cause) {
      set({ detailLoading: false, actionError: errorMessage(cause, 'Could not open the inbox item.') });
    }
  },

  async sendReply(fingerprint, bodyMarkdown) {
    const body = bodyMarkdown.trim();
    if (!body) return null;
    const bridge = inboxBridge();
    if (!bridge?.inboxReply || useShellStore.getState().fixtureMode) {
      set({ refusalReason: useShellStore.getState().fixtureMode ? 'Fixture mode does not call a model.' : 'Reply is unavailable in this shell.' });
      return null;
    }
    const key = `reply:${fingerprint}`;
    set((state) => ({ busy: { ...state.busy, [key]: true }, refusalReason: null, actionError: null }));
    try {
      const response = await bridge.inboxReply({ fingerprint, bodyMarkdown: body });
      const thread = (await bridge.inboxThreadGet(fingerprint)).thread ?? null;
      set((state) => ({
        threads: { ...state.threads, [fingerprint]: thread },
        refusalReason: response.refusalReason ?? null,
        busy: { ...state.busy, [key]: false }
      }));
      return response;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not send the reply.'),
        busy: { ...state.busy, [key]: false }
      }));
      return null;
    }
  },

  async acceptCandidate(candidate, pack = 'engOps') {
    const bridge = inboxBridge();
    if (!bridge?.inboxPlansAccept || useShellStore.getState().fixtureMode) {
      set({ actionError: useShellStore.getState().fixtureMode ? null : 'Plan acceptance is unavailable in this shell.' });
      return useShellStore.getState().fixtureMode;
    }
    const key = `accept:${candidate.planID ?? 'new'}:${candidate.title}`;
    set((state) => ({ busy: { ...state.busy, [key]: true }, actionError: null }));
    try {
      await bridge.inboxPlansAccept({ candidate, pack });
      await get().loadPlans();
      set((state) => ({ busy: { ...state.busy, [key]: false } }));
      return true;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not accept the plan step.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  async updateStep(stepID, status, missionID, followupID) {
    const bridge = inboxBridge();
    if (!bridge?.inboxPlansUpdateStep || useShellStore.getState().fixtureMode) return useShellStore.getState().fixtureMode;
    const key = `step:${stepID}`;
    set((state) => ({ busy: { ...state.busy, [key]: true }, actionError: null }));
    try {
      await bridge.inboxPlansUpdateStep({ stepID, status, missionID, followupID });
      await get().loadPlans();
      set((state) => ({ busy: { ...state.busy, [key]: false } }));
      return true;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not update the plan step.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  async gradeStep(stepID, grade, noteMarkdown) {
    const bridge = inboxBridge();
    if (!bridge?.inboxPlansGrade || useShellStore.getState().fixtureMode) return useShellStore.getState().fixtureMode;
    const key = `step:${stepID}`;
    set((state) => ({ busy: { ...state.busy, [key]: true }, actionError: null }));
    try {
      await bridge.inboxPlansGrade({ stepID, grade, noteMarkdown });
      await get().loadPlans();
      set((state) => ({ busy: { ...state.busy, [key]: false } }));
      return true;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not grade the plan step.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  async promoteStep(plan, stepID) {
    const step = plan.steps.find((entry) => entry.id === stepID);
    const projectSlug = get().rows.find((row) => row.item.summary.id === get().selectedID)?.item.summary.projectID;
    const bridge = inboxBridge();
    if (!step || !projectSlug || !bridge?.missionCreate) {
      set({ actionError: 'This item needs a project before it can become a mission.' });
      return false;
    }
    const key = `step:${stepID}`;
    set((state) => ({ busy: { ...state.busy, [key]: true }, actionError: null }));
    try {
      const mission = await bridge.missionCreate({
        projectSlug,
        title: step.title,
        summary: `${plan.title}\n\n${step.bodyMarkdown}`
      });
      if (!mission) throw new Error('Mission Control did not return the created mission.');
      const updated = await get().updateStep(stepID, 'in_progress', mission.id);
      set((state) => ({ busy: { ...state.busy, [key]: false } }));
      return updated;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not promote this step to Mission Control.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  async approveMemoryCandidate(itemID, fingerprint, candidateID) {
    const bridge = inboxBridge();
    if (!bridge?.inboxMemoryCandidateApprove || useShellStore.getState().fixtureMode) {
      set({
        actionError: useShellStore.getState().fixtureMode
          ? null
          : 'Memory approval is unavailable in this shell.'
      });
      return useShellStore.getState().fixtureMode;
    }
    const key = `memory:${itemID}:${candidateID}`;
    set((state) => ({ busy: { ...state.busy, [key]: true }, actionError: null }));
    try {
      await bridge.inboxMemoryCandidateApprove({ itemID, fingerprint, candidateID });
      set((state) => ({ busy: { ...state.busy, [key]: false } }));
      return true;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not remember this proposal.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  async rememberStep(stepID) {
    const bridge = inboxBridge();
    if (!bridge?.inboxPlansRememberStep || useShellStore.getState().fixtureMode) {
      set({
        actionError: useShellStore.getState().fixtureMode
          ? null
          : 'Founder Plan memory is unavailable in this shell.'
      });
      return useShellStore.getState().fixtureMode;
    }
    const key = `step:${stepID}`;
    set((state) => ({ busy: { ...state.busy, [key]: true }, actionError: null }));
    try {
      const response = await bridge.inboxPlansRememberStep({ stepID });
      set((state) => ({
        plans: replacePlan(state.plans, response.plan),
        busy: { ...state.busy, [key]: false }
      }));
      return true;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not remember this plan step.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  async createFollowup(stepID) {
    const projectSlug = get().rows.find(
      (row) => row.item.summary.id === get().selectedID
    )?.item.summary.projectID;
    const bridge = inboxBridge();
    if (!projectSlug) {
      set({ actionError: 'This item needs a project before it can create a follow-up.' });
      return false;
    }
    if (!bridge?.inboxPlansCreateFollowup || useShellStore.getState().fixtureMode) {
      set({
        actionError: useShellStore.getState().fixtureMode
          ? null
          : 'Founder Plan follow-up creation is unavailable in this shell.'
      });
      return useShellStore.getState().fixtureMode;
    }
    const key = `step:${stepID}`;
    set((state) => ({ busy: { ...state.busy, [key]: true }, actionError: null }));
    try {
      const response = await bridge.inboxPlansCreateFollowup({ stepID, projectSlug });
      set((state) => ({
        plans: replacePlan(state.plans, response.plan),
        busy: { ...state.busy, [key]: false }
      }));
      return true;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not create a follow-up from this plan step.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  async mutatePresentation(itemID, action, options = {}) {
    const key = `presentation:${itemID}`;
    if (get().busy[key]) return false;
    const fixtureMode = useShellStore.getState().fixtureMode;
    const current = get().rows.find((row) => row.item.summary.id === itemID);
    if (fixtureMode) {
      if (!current) return false;
      const row = fixtureMutation(current, action, options);
      const rows = replacePresentationRow(get().rows, row);
      set((state) => ({
        rows,
        activeUnreadCount: activeUnreadCount(rows),
        busy: { ...state.busy, [key]: false },
        actionError: null
      }));
      return true;
    }
    const bridge = inboxBridge();
    if (!bridge?.inboxPresentationMutate) {
      set({ actionError: 'The installed Linux shell cannot update Inbox presentation state.' });
      return false;
    }
    set((state) => ({
      busy: { ...state.busy, [key]: true },
      actionError: null
    }));
    try {
      const response = await bridge.inboxPresentationMutate({
        itemID,
        action,
        ...options
      });
      set((state) => ({
        rows: replacePresentationRow(state.rows, response.row),
        busy: { ...state.busy, [key]: false }
      }));
      await get().load();
      return true;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not update this Inbox item.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  async toggleRead(itemID) {
    const row = get().rows.find((entry) => entry.item.summary.id === itemID);
    if (!row) return false;
    return get().mutatePresentation(
      itemID,
      row.presentation.readAt === undefined ? 'mark_read' : 'mark_unread'
    );
  },

  async setArchived(itemID, archived) {
    return get().mutatePresentation(itemID, archived ? 'archive' : 'unarchive');
  },

  async setSnooze(itemID, until) {
    return get().mutatePresentation(
      itemID,
      until === undefined ? 'clear_snooze' : 'snooze',
      until === undefined ? undefined : { snoozedUntil: until }
    );
  },

  async setFeedback(itemID, feedback) {
    return get().mutatePresentation(
      itemID,
      feedback === undefined ? 'clear_feedback' : 'set_feedback',
      feedback === undefined ? undefined : { feedback }
    );
  },

  async markAllRead() {
    if (useShellStore.getState().fixtureMode) {
      const now = new Date().toISOString();
      const rows = get().rows.map((row) =>
        isOpen(row)
          ? { ...row, presentation: { ...row.presentation, readAt: row.presentation.readAt ?? now, updatedAt: now } }
          : row
      );
      set({ rows, activeUnreadCount: 0, actionError: null });
      return true;
    }
    const bridge = inboxBridge();
    if (!bridge?.inboxPresentationMarkAllRead) {
      set({ actionError: 'The installed Linux shell cannot mark Inbox items read.' });
      return false;
    }
    const key = 'presentation:mark-all-read';
    if (get().busy[key]) return false;
    set((state) => ({ busy: { ...state.busy, [key]: true }, actionError: null }));
    try {
      const response = await bridge.inboxPresentationMarkAllRead();
      set((state) => ({
        activeUnreadCount: response.activeUnreadCount,
        busy: { ...state.busy, [key]: false }
      }));
      await get().load();
      return true;
    } catch (cause) {
      set((state) => ({
        actionError: errorMessage(cause, 'Could not mark the Inbox read.'),
        busy: { ...state.busy, [key]: false }
      }));
      return false;
    }
  },

  reportActionError(message) {
    set({ actionError: message });
  },

  clearActionError() {
    set({ actionError: null, refusalReason: null });
  }
}));
