import { describe, expect, it } from 'vitest';
import { bridgeStubDefaults } from './testing/bridgeStubs';
import {
  computeCacheHitRatePct,
  decodeChatMessageAppend,
  decodeChatThreadGet,
  decodeChatThreadList,
  decodeDaemonSubscriptionResponse,
  decodeDaemonSubscriptionStopResponse
} from './tauriBridge';

const ACCOUNT_UPDATED_AT = '2026-07-10T12:00:00Z';

const CHAT_THREAD = {
  id: 'thread-1',
  title: 'Release check',
  preview: 'Verify the Linux package',
  messageCount: 2,
  createdAt: ACCOUNT_UPDATED_AT,
  updatedAt: ACCOUNT_UPDATED_AT,
  lastMessageAt: ACCOUNT_UPDATED_AT,
  backendID: 'codex'
};

const CHAT_MESSAGE = {
  id: 'message-1',
  threadID: 'thread-1',
  role: 'user',
  content: 'Verify the package.',
  timestamp: ACCOUNT_UPDATED_AT,
  backendID: 'codex'
};

describe('exact-thread chat wire decoding', () => {
  it('strictly decodes list, get, and idempotent append results', () => {
    expect(decodeChatThreadList({ threads: [CHAT_THREAD] })).toEqual({ threads: [CHAT_THREAD] });
    expect(decodeChatThreadGet({
      thread: CHAT_THREAD,
      messages: [CHAT_MESSAGE],
      hasMoreBefore: false
    })).toMatchObject({ thread: CHAT_THREAD, messages: [CHAT_MESSAGE], hasMoreBefore: false });
    expect(decodeChatMessageAppend({ message: CHAT_MESSAGE, inserted: false })).toEqual({
      message: CHAT_MESSAGE,
      inserted: false
    });
  });

  it('rejects malformed roles, cross-thread messages, oversized bodies, and result floods', () => {
    expect(() => decodeChatThreadGet({
      thread: CHAT_THREAD,
      messages: [{ ...CHAT_MESSAGE, role: 'tool' }],
      hasMoreBefore: false
    })).toThrow('role');
    expect(() => decodeChatThreadGet({
      thread: CHAT_THREAD,
      messages: [{ ...CHAT_MESSAGE, threadID: 'thread-2' }],
      hasMoreBefore: false
    })).toThrow('different thread');
    expect(() => decodeChatThreadGet({
      messages: [CHAT_MESSAGE],
      hasMoreBefore: false
    })).toThrow('thread is missing');
    expect(() => decodeChatMessageAppend({
      message: { ...CHAT_MESSAGE, content: 'x'.repeat(262_145) },
      inserted: true
    })).toThrow('262144');
    expect(() => decodeChatThreadList({ threads: Array.from({ length: 101 }, () => CHAT_THREAD) }))
      .toThrow('100');
  });

  it('renders a missing thread as an honest empty exact-thread result', () => {
    expect(decodeChatThreadGet({ messages: [], hasMoreBefore: false })).toEqual({
      thread: undefined,
      messages: [],
      hasMoreBefore: false
    });
  });
});
describe('computeCacheHitRatePct', () => {
  it('matches the macOS CacheEfficiency formula (prompt-side basis)', () => {
    // hitRate = cacheRead / (input + cacheCreation + cacheRead)
    const events = [
      { inputTokens: 600, cacheCreationTokens: 60, cacheReadTokens: 340, outputTokens: 9999 }
    ];
    expect(computeCacheHitRatePct(events)).toBe(34);
  });

  it('aggregates across multiple events', () => {
    const events = [
      { inputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 100 },
      { inputTokens: 100, cacheCreationTokens: 100, cacheReadTokens: 0 }
    ];
    // read=100, basis=400 -> 25%
    expect(computeCacheHitRatePct(events)).toBe(25);
  });

  it('reads token fields nested under event', () => {
    const events = [
      { event: { inputTokens: 50, cacheCreationTokens: 0, cacheReadTokens: 50 } }
    ];
    expect(computeCacheHitRatePct(events)).toBe(50);
  });

  it('returns 0 when there is no prompt-side basis', () => {
    expect(computeCacheHitRatePct([])).toBe(0);
    expect(computeCacheHitRatePct([{ outputTokens: 500 }])).toBe(0);
  });

  it('ignores negative token counts', () => {
    const events = [{ inputTokens: -10, cacheCreationTokens: 0, cacheReadTokens: 100 }];
    expect(computeCacheHitRatePct(events)).toBe(100);
  });
});

describe('bridgeStubDefaults media wiring', () => {
  it('keeps full-shape bridge mocks current for live media methods', async () => {
    await expect(bridgeStubDefaults.computerUsePanicHalt()).resolves.toMatchObject({ sessionId: '*', source: 'hotkey' });
    await expect(bridgeStubDefaults.mediaSessionState()).resolves.toMatchObject({ phase: 'capability-absent' });
    await expect(bridgeStubDefaults.mediaAcceptCall('req')).resolves.toMatchObject({ phase: 'capability-absent' });
    await expect(bridgeStubDefaults.mediaDeclineCall('req')).resolves.toMatchObject({ phase: 'capability-absent' });
    await expect(bridgeStubDefaults.mediaEndCall()).resolves.toMatchObject({ phase: 'capability-absent' });
    await expect(bridgeStubDefaults.mediaCapabilityGet()).resolves.toMatchObject({ available: false });
  });
});

describe('daemon subscription wire decoding', () => {
  it('strictly decodes the snake-case Swift response', () => {
    expect(decodeDaemonSubscriptionResponse({
      subscription_id: 'sub-data',
      topic: 'data',
      seq: 2,
      cursor: '2',
      first_snapshot: false,
      events: [{
        seq: 2,
        kind: 'data.tick',
        snapshot: { daemon_session_id: 'daemon-a' },
        terminal: false
      }],
      degraded_fallback: true,
      degradation_reason: 'bounded_pull_over_burnbarrpc_envelope',
      backpressure: 'coalesce_latest_per_topic',
      disconnect_detected: true,
      recovered_after_restart: true,
      terminal_state_delivered: false
    })).toMatchObject({
      subscriptionId: 'sub-data',
      seq: 2,
      recoveredAfterRestart: true,
      terminalStateDelivered: false
    });
  });

  it('rejects malformed cursor and terminal-state fields', () => {
    expect(() => decodeDaemonSubscriptionResponse({
      subscription_id: 'sub-data',
      topic: 'data',
      seq: -1,
      cursor: 'bad',
      first_snapshot: true,
      events: [],
      degraded_fallback: true,
      backpressure: 'coalesce_latest_per_topic',
      disconnect_detected: false,
      recovered_after_restart: false,
      terminal_state_delivered: 'false'
    })).toThrow('subscription.seq');
  });

  it('strictly decodes stop acknowledgement fields', () => {
    expect(decodeDaemonSubscriptionStopResponse({
      subscription_id: 'sub-data',
      stopped: true,
      last_seq: 8
    })).toEqual({ subscriptionId: 'sub-data', stopped: true, lastSeq: 8 });
  });
});
