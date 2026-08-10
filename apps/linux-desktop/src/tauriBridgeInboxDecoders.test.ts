import { describe, expect, it } from 'vitest';
import {
  decodeAIInboxConfig,
  decodeAIInboxGetResponse,
  decodeAIInboxListResponse,
  decodeAIInboxMemoryExportResponse,
  decodeAIInboxPlanAcceptResponse,
  decodeAIInboxPlanGetResponse,
  decodeAIInboxPlanGradeResponse,
  decodeAIInboxPlansListResponse,
  decodeAIInboxPlanUpdateStepResponse,
  decodeAIInboxPresentationGetResponse,
  decodeAIInboxPresentationListResponse,
  decodeAIInboxPresentationMarkAllReadResponse,
  decodeAIInboxPresentationMutationResponse,
  decodeAIInboxReplyResponse,
  decodeAIInboxRunNowResponse,
  decodeAIInboxRunsResponse,
  decodeAIInboxThreadGetResponse,
  decodeSwiftDate,
  encodeAIInboxConfig,
  encodeAIInboxListRequest,
  encodeAIInboxMemoryExportRequest,
  encodeAIInboxPlanAcceptRequest,
  encodeAIInboxPlanGradeRequest,
  encodeAIInboxPlansListRequest,
  encodeAIInboxPlanUpdateStepRequest,
  encodeAIInboxPresentationListRequest,
  encodeAIInboxPresentationMarkAllReadRequest,
  encodeAIInboxPresentationMutationRequest,
  encodeAIInboxRunsRequest,
  encodeSwiftDate
} from './tauriBridgeInboxDecoders.js';
import type { AIInboxConfig } from './tauriBridgeTypes.js';

const FOUNDATION_REFERENCE_UNIX_MS = Date.UTC(2001, 0, 1);
const ISO = '2026-08-10T12:34:56.000Z';
const SWIFT_DATE = (Date.parse(ISO) - FOUNDATION_REFERENCE_UNIX_MS) / 1_000;

const config = (overrides: Partial<AIInboxConfig> = {}): AIInboxConfig => ({
  enabled: true,
  egressMode: 'local',
  tickSeconds: 300,
  remotePhaseEveryNTicks: 3,
  dailyBudgetUSD: 1.5,
  maxVerifierCallsPerTick: 3,
  perTickPromptTokenCap: 60_000,
  analystProviderID: 'deepseek',
  analystModel: 'deepseek-v4-flash',
  verifierProviderID: 'openai',
  verifierModel: 'gpt-5.6-luna',
  githubEnabled: true,
  notifyOnP1: true,
  lookbackMinutes: 120,
  founderLensEnabled: true,
  perReplyBudgetUSD: 0.1,
  maxThreadTurns: 40,
  budgetCountsSubscriptionSpend: false,
  ...overrides
});

const itemSummary = () => ({
  id: 'inb_1',
  fingerprint: 'ci_waste:linux',
  kind: 'ci_waste',
  priority: 9,
  state: 'updated',
  title: 'CI is burning cycles',
  projectID: 'burnbar',
  projectName: 'BurnBar',
  occurrenceCount: -2,
  firstSeenAt: SWIFT_DATE,
  lastSeenAt: ISO,
  resolvedAt: null,
  resolutionNote: null,
  modelProvenance: 'local-rules+lens:v1',
  hasMemoryCandidates: true
});

const itemDetail = () => ({
  summary: itemSummary(),
  summaryMarkdown: 'A bounded brief.',
  tickID: 'tick_1',
  payload: {
    version: 1,
    evidence: [],
    memoryCandidates: [],
    actions: [],
    metrics: {},
    verification: null
  }
});

const planCandidate = () => ({
  title: 'Land the gate',
  bodyMarkdown: 'Make the compile gate mandatory.',
  horizon: 'week',
  evidenceIDs: ['workflow:42'],
  planID: null
});

const threadMessage = () => ({
  id: 'turn_1',
  fingerprint: 'ci_waste:linux',
  role: 'assistant',
  bodyMarkdown: 'Ship the compile gate first.',
  planCandidates: [planCandidate()],
  modelProvenance: 'deepseek:deepseek-v4-flash+lens:v1',
  costUSD: -1,
  createdAt: SWIFT_DATE
});

const planStep = () => ({
  id: 'step_1',
  planID: 'plan_1',
  parentStepID: null,
  ordinal: -4,
  title: 'Land compile gate',
  bodyMarkdown: 'Make it required.',
  status: 'in_progress',
  nextMoveMarkdown: 'Open the PR.',
  evidenceIDs: ['workflow:42'],
  missionID: 'mission_1',
  followupID: null,
  inboxFingerprint: 'ci_waste:linux',
  grade: 140,
  gradeNoteMarkdown: 'Strong result.',
  gradedAt: SWIFT_DATE,
  createdAt: SWIFT_DATE,
  updatedAt: SWIFT_DATE,
  completedAt: null
});

const plan = () => ({
  id: 'plan_1',
  title: 'Kill CI waste',
  horizon: 'quarter',
  pack: 'engOps',
  status: 'active',
  summaryMarkdown: 'Make CI earn its keep.',
  createdAt: SWIFT_DATE,
  updatedAt: SWIFT_DATE,
  originFingerprint: 'ci_waste:linux',
  memoryID: null,
  pensieveVectorID: null,
  gradeAverage: -5,
  steps: [planStep()]
});

describe('AI Inbox Swift boundary dates and primitive validation', () => {
  it('converts default Swift Date numbers and validated ISO strings to canonical ISO', () => {
    expect(decodeSwiftDate(SWIFT_DATE, 'date')).toBe(ISO);
    expect(decodeSwiftDate('2026-08-10T12:34:56Z', 'date')).toBe(ISO);
    expect(encodeSwiftDate(ISO, 'date')).toBe(SWIFT_DATE);
    expect(() => decodeSwiftDate('not-a-date', 'date')).toThrow('must be a valid date');
    expect(() => encodeSwiftDate('not-a-date', 'date')).toThrow('must be a valid ISO-8601 date');
  });

  it('decodes list/detail payloads, preserves exact Swift field names, and clamps bounded values', () => {
    const list = decodeAIInboxListResponse({
      items: [itemSummary()],
      nextBefore: SWIFT_DATE,
      openCount: -10
    });
    expect(list).toEqual({
      items: [{
        id: 'inb_1',
        fingerprint: 'ci_waste:linux',
        kind: 'ci_waste',
        priority: 4,
        state: 'updated',
        title: 'CI is burning cycles',
        projectID: 'burnbar',
        projectName: 'BurnBar',
        occurrenceCount: 0,
        firstSeenAt: ISO,
        lastSeenAt: ISO,
        modelProvenance: 'local-rules+lens:v1',
        hasMemoryCandidates: true
      }],
      nextBefore: ISO,
      openCount: 0
    });

    const detail = decodeAIInboxGetResponse({
      item: {
        summary: itemSummary(),
        summaryMarkdown: 'A bounded brief.',
        tickID: 'tick_1',
        payload: {
          version: 1,
          evidence: [{
            id: 'workflow:42',
            kind: 'workflow_run',
            label: 'CI #42',
            detail: null,
            url: 'https://example.invalid/42',
            occurredAt: SWIFT_DATE
          }],
          memoryCandidates: [{
            id: 'mem_1',
            text: 'Compile before review.',
            kind: 'convention',
            confidence: 7,
            citationConversationIDs: ['conversation_1']
          }],
          actions: [{
            id: 'action_1',
            kind: 'open_project',
            title: 'Open BurnBar',
            value: 'burnbar',
            isPrimary: true
          }],
          metrics: { failure_rate: '0.95' },
          verification: {
            verdict: 'deterministic',
            reason: null,
            checkedAt: SWIFT_DATE,
            verifierModel: null
          }
        }
      }
    });
    expect(detail.item?.tickID).toBe('tick_1');
    expect(detail.item?.payload.memoryCandidates[0]?.confidence).toBe(1);
    expect(detail.item?.payload.evidence[0]?.occurredAt).toBe(ISO);
    expect(detail.item?.payload.verification?.checkedAt).toBe(ISO);
    expect(decodeAIInboxGetResponse({ item: null })).toEqual({});
  });

  it('rejects malformed enums, missing required fields, and unsupported payload versions', () => {
    expect(() => decodeAIInboxListResponse({
      items: [{ ...itemSummary(), kind: 'invented_kind' }],
      openCount: 1
    })).toThrow('kind is unsupported');
    expect(() => decodeAIInboxGetResponse({
      item: {
        summary: itemSummary(),
        summaryMarkdown: 'x',
        tickID: 'tick',
        payload: {
          version: 2,
          evidence: [],
          memoryCandidates: [],
          actions: [],
          metrics: {},
          verification: null
        }
      }
    })).toThrow('version is unsupported');
  });
});

describe('AI Inbox telemetry and configuration decoding', () => {
  it('decodes telemetry and clamps daemon counters/spend without accepting invalid gate enums', () => {
    const result = decodeAIInboxRunsResponse({
      runs: [{
        tickID: 'tick_1',
        startedAt: SWIFT_DATE,
        finishedAt: SWIFT_DATE,
        gateResult: 'forced',
        egressMode: 'cloud',
        llmCalls: -1,
        inputTokens: 12,
        outputTokens: 4,
        costUSD: -2,
        itemsNew: 1,
        itemsUpdated: 2,
        itemsResolved: 3,
        error: null
      }],
      todaySpendUSD: -4,
      dailyBudgetUSD: 1.5
    });
    expect(result.runs[0]).toMatchObject({
      tickID: 'tick_1',
      startedAt: ISO,
      finishedAt: ISO,
      llmCalls: 0,
      costUSD: 0
    });
    expect(result.todaySpendUSD).toBe(0);
    expect(() => decodeAIInboxRunsResponse({
      runs: [{
        tickID: 'tick',
        startedAt: SWIFT_DATE,
        finishedAt: null,
        gateResult: 'maybe',
        egressMode: 'off',
        llmCalls: 0,
        inputTokens: 0,
        outputTokens: 0,
        costUSD: 0,
        itemsNew: 0,
        itemsUpdated: 0,
        itemsResolved: 0,
        error: null
      }],
      todaySpendUSD: 0,
      dailyBudgetUSD: 0
    })).toThrow('gateResult is unsupported');
  });

  it('clamps config using the same bounds as BurnBarInboxConfig', () => {
    expect(decodeAIInboxConfig(config({
      tickSeconds: 1,
      remotePhaseEveryNTicks: 100,
      dailyBudgetUSD: -1,
      maxVerifierCallsPerTick: 90,
      perTickPromptTokenCap: 1,
      lookbackMinutes: 99_999,
      perReplyBudgetUSD: 40,
      maxThreadTurns: 1
    }))).toMatchObject({
      tickSeconds: 60,
      remotePhaseEveryNTicks: 60,
      dailyBudgetUSD: 0,
      maxVerifierCallsPerTick: 25,
      perTickPromptTokenCap: 2_000,
      lookbackMinutes: 1_440,
      perReplyBudgetUSD: 5,
      maxThreadTurns: 2
    });
    expect(encodeAIInboxConfig(config({ tickSeconds: 9_999 })).tickSeconds).toBe(3_600);
    expect(() => decodeAIInboxConfig({ ...config(), egressMode: 'internet' })).toThrow(
      'egressMode is unsupported'
    );
  });

  it('decodes run-now and memory-export acknowledgements strictly', () => {
    expect(decodeAIInboxRunNowResponse({
      tickID: null,
      accepted: false,
      reason: 'The AI Inbox is turned off.'
    })).toEqual({ accepted: false, reason: 'The AI Inbox is turned off.' });
    expect(decodeAIInboxMemoryExportResponse({ stored: -2 })).toEqual({ stored: 0 });
    expect(() => decodeAIInboxRunNowResponse({ accepted: 'yes' })).toThrow(
      'accepted must be a boolean'
    );
  });
});

describe('AI Inbox shared presentation decoding', () => {
  it('decodes full presentation rows and daemon-owned unread counts', () => {
    const result = decodeAIInboxPresentationListResponse({
      rows: [{
        item: itemDetail(),
        presentation: {
          readAt: null,
          archivedAt: SWIFT_DATE,
          snoozedUntil: SWIFT_DATE,
          feedback: 'not_useful',
          updatedAt: SWIFT_DATE
        }
      }],
      nextBefore: SWIFT_DATE,
      openCount: -1,
      activeUnreadCount: 999
    });
    expect(result).toMatchObject({
      nextBefore: ISO,
      openCount: 0,
      activeUnreadCount: 999
    });
    expect(result.rows[0]?.item.tickID).toBe('tick_1');
    expect(result.rows[0]?.presentation).toEqual({
      archivedAt: ISO,
      snoozedUntil: ISO,
      feedback: 'not_useful',
      updatedAt: ISO
    });
  });

  it('decodes get/mutate/mark-all responses and rejects unknown feedback', () => {
    expect(decodeAIInboxPresentationGetResponse({ row: null })).toEqual({});
    expect(decodeAIInboxPresentationMutationResponse({
      row: {
        item: itemDetail(),
        presentation: { readAt: SWIFT_DATE, updatedAt: SWIFT_DATE }
      }
    }).row.presentation.readAt).toBe(ISO);
    expect(decodeAIInboxPresentationMarkAllReadResponse({
      updatedCount: -4,
      readAt: SWIFT_DATE,
      activeUnreadCount: -1
    })).toEqual({
      updatedCount: 0,
      readAt: ISO,
      activeUnreadCount: 0
    });
    expect(() => decodeAIInboxPresentationListResponse({
      rows: [{
        item: itemDetail(),
        presentation: { feedback: 'maybe' }
      }],
      openCount: 1,
      activeUnreadCount: 1
    })).toThrow('feedback is unsupported');
  });

  it('preserves the list default/all-states distinction and exact filter keys', () => {
    expect(encodeAIInboxPresentationListRequest()).toEqual({ limit: 200 });
    expect(encodeAIInboxPresentationListRequest({
      states: null,
      kinds: ['brief'],
      priorities: [0 as 1, 9 as 4],
      projectID: 'burnbar',
      isUnread: true,
      isArchived: false,
      isSnoozed: false,
      feedback: 'useful',
      limit: 999,
      before: ISO
    })).toEqual({
      states: null,
      kinds: ['brief'],
      priorities: [1, 4],
      projectID: 'burnbar',
      isUnread: true,
      isArchived: false,
      isSnoozed: false,
      feedback: 'useful',
      limit: 300,
      before: SWIFT_DATE
    });
  });

  it('validates action-specific mutation payloads before invoking the daemon', () => {
    expect(encodeAIInboxPresentationMutationRequest({
      itemID: 'inb_1',
      action: 'snooze',
      snoozedUntil: ISO
    })).toEqual({
      itemID: 'inb_1',
      action: 'snooze',
      snoozedUntil: SWIFT_DATE
    });
    expect(encodeAIInboxPresentationMutationRequest({
      itemID: 'inb_1',
      action: 'set_feedback',
      feedback: 'not_useful'
    })).toEqual({
      itemID: 'inb_1',
      action: 'set_feedback',
      feedback: 'not_useful'
    });
    expect(encodeAIInboxPresentationMutationRequest({
      itemID: 'inb_1',
      action: 'archive'
    })).toEqual({ itemID: 'inb_1', action: 'archive' });
    expect(encodeAIInboxPresentationMarkAllReadRequest()).toEqual({});
    expect(() => encodeAIInboxPresentationMutationRequest({
      itemID: 'inb_1',
      action: 'snooze'
    })).toThrow('requires snoozedUntil');
    expect(() => encodeAIInboxPresentationMutationRequest({
      itemID: 'inb_1',
      action: 'mark_read',
      feedback: 'useful'
    })).toThrow('does not accept snoozedUntil or feedback');
  });
});

describe('Founder Lens thread and plan decoding', () => {
  it('decodes replies, thread history, plans, updates, grades, and absent rows', () => {
    const thread = decodeAIInboxThreadGetResponse({
      thread: {
        fingerprint: 'ci_waste:linux',
        itemID: 'inb_1',
        createdAt: SWIFT_DATE,
        updatedAt: SWIFT_DATE,
        turnCount: -1,
        totalCostUSD: -2,
        messages: [threadMessage()]
      }
    });
    expect(thread.thread).toMatchObject({
      fingerprint: 'ci_waste:linux',
      turnCount: 0,
      totalCostUSD: 0,
      createdAt: ISO
    });
    expect(thread.thread?.messages[0]).toMatchObject({
      costUSD: 0,
      createdAt: ISO
    });
    expect(decodeAIInboxThreadGetResponse({ thread: null })).toEqual({});
    expect(decodeAIInboxReplyResponse({
      message: null,
      refusalReason: 'Founder Lens replies are turned off.'
    })).toEqual({ refusalReason: 'Founder Lens replies are turned off.' });
    expect(() => decodeAIInboxReplyResponse({ message: null, refusalReason: null })).toThrow(
      'must contain a message or refusalReason'
    );

    const plans = decodeAIInboxPlansListResponse({ plans: [plan()] });
    expect(plans.plans[0]).toMatchObject({
      pack: 'engOps',
      gradeAverage: 0,
      createdAt: ISO
    });
    expect(plans.plans[0]?.steps[0]).toMatchObject({
      planID: 'plan_1',
      ordinal: 0,
      grade: 100,
      gradedAt: ISO
    });
    expect(decodeAIInboxPlanGetResponse({ plan: null })).toEqual({});
    expect(decodeAIInboxPlanAcceptResponse({ plan: plan(), step: planStep() }).step.grade).toBe(100);
    expect(decodeAIInboxPlanUpdateStepResponse({ step: planStep() }).step.status).toBe('in_progress');
    expect(decodeAIInboxPlanGradeResponse({
      step: planStep(),
      planGradeAverage: 101
    }).planGradeAverage).toBe(100);
  });

  it('rejects unknown Founder Lens packs and plan statuses', () => {
    expect(() => decodeAIInboxPlansListResponse({
      plans: [{ ...plan(), pack: 'freeTextPack' }]
    })).toThrow('pack is unsupported');
    expect(() => decodeAIInboxPlanUpdateStepResponse({
      step: { ...planStep(), status: 'done' }
    })).toThrow('status is unsupported');
  });
});

describe('AI Inbox outbound request normalization', () => {
  it('preserves exact Swift keys, clamps list/run/plan limits, and encodes before as Swift Date', () => {
    expect(encodeAIInboxListRequest({
      states: ['new'],
      kinds: ['brief'],
      projectID: 'burnbar',
      limit: 999,
      before: ISO
    })).toEqual({
      states: ['new'],
      kinds: ['brief'],
      projectID: 'burnbar',
      limit: 300,
      before: SWIFT_DATE
    });
    expect(encodeAIInboxRunsRequest(-4)).toEqual({ limit: 1 });
    expect(encodeAIInboxPlansListRequest({ statuses: ['active'], limit: 999 })).toEqual({
      statuses: ['active'],
      limit: 200
    });
  });

  it('validates plan mutations and clamps grade before the daemon call', () => {
    expect(encodeAIInboxPlanAcceptRequest({
      candidate: {
        title: 'Land gate',
        bodyMarkdown: 'Make it required.',
        horizon: 'week',
        evidenceIDs: ['workflow:42']
      },
      pack: 'engOps'
    })).toEqual({
      candidate: {
        title: 'Land gate',
        bodyMarkdown: 'Make it required.',
        horizon: 'week',
        evidenceIDs: ['workflow:42']
      },
      pack: 'engOps'
    });
    expect(encodeAIInboxPlanUpdateStepRequest({
      stepID: 'step_1',
      status: 'landed',
      missionID: 'mission_1'
    })).toEqual({
      stepID: 'step_1',
      status: 'landed',
      missionID: 'mission_1'
    });
    expect(encodeAIInboxPlanGradeRequest({
      stepID: 'step_1',
      grade: 900,
      noteMarkdown: 'Done.'
    })).toEqual({
      stepID: 'step_1',
      grade: 100,
      noteMarkdown: 'Done.'
    });
  });

  it('encodes approvedAt as Foundation reference-date seconds for memory export', () => {
    expect(encodeAIInboxMemoryExportRequest({
      entries: [{
        memoryID: 'mem_1',
        provenance: 'ai-inbox:plan:plan_1',
        snippetMarkdown: 'Compile before review.',
        approvedAt: ISO
      }]
    })).toEqual({
      entries: [{
        memoryID: 'mem_1',
        provenance: 'ai-inbox:plan:plan_1',
        snippetMarkdown: 'Compile before review.',
        approvedAt: SWIFT_DATE
      }]
    });
  });
});
