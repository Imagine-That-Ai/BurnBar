import { describe, expect, it } from 'vitest';
import { bridgeStubDefaults } from './testing/bridgeStubs';
import {
  computeCacheHitRatePct,
  decodeDaemonSubscriptionResponse,
  decodeDaemonSubscriptionStopResponse,
  decodeNativeDeepLink,
  decodeNativeShellSnapshot
} from './tauriBridge';

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

describe('native shell wire decoding', () => {
  it('accepts only supported route and action pairs', () => {
    expect(decodeNativeDeepLink({ route: 'account', action: 'membership-success' })).toEqual({
      route: 'account',
      action: 'membership-success'
    });
    expect(() => decodeNativeDeepLink({ route: 'account', action: 'open-chat' })).toThrow(
      'route/action pair'
    );
  });

  it('strictly validates snapshot state and bounded rejected-link counts', () => {
    expect(decodeNativeShellSnapshot({
      loginStartEnabled: true,
      loginStartPath: '/home/alice/.config/autostart/dev.openburnbar.OpenBurnBar.desktop',
      backgroundLaunch: false,
      rejectedDeepLinks: 2,
      degradedReason: null
    })).toMatchObject({ loginStartEnabled: true, rejectedDeepLinks: 2 });
    expect(() => decodeNativeShellSnapshot({
      loginStartEnabled: 'true',
      backgroundLaunch: false,
      rejectedDeepLinks: 0
    })).toThrow('loginStartEnabled');
  });
});
