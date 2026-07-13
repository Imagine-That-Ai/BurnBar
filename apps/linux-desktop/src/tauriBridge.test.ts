import { describe, expect, it } from 'vitest';
import { bridgeStubDefaults } from './testing/bridgeStubs';
import {
  computeCacheHitRatePct,
  decodeDaemonSubscriptionResponse,
  decodeDaemonSubscriptionStopResponse,
  decodeLinuxUpdateStatus
} from './tauriBridge';

describe('native Linux update status decoding', () => {
  it('decodes freshness, channel ownership, signature, and compatibility metadata', () => {
    const decoded = decodeLinuxUpdateStatus({
      state: 'available',
      currentVersion: '1.0.0',
      latestVersion: '1.1.0',
      signatureState: 'verified',
      feedFreshness: 'fresh',
      feedAgeSeconds: 42,
      checkedAtUnixSeconds: 1_750_000_000,
      packageChannel: 'deb',
      channelInfo: {
        id: 'deb',
        label: 'Debian package (.deb)',
        owner: 'apt/dpkg',
        installMode: 'package-manager-guided',
        automaticInstall: false,
        rollbackMode: 'apt-version-selection',
        explanation: 'The distro package manager owns files.'
      },
      compatibility: {
        state: 'aligned',
        shellVersion: '1.0.0',
        daemonVersion: '1.0.0'
      }
    });
    expect(decoded).toMatchObject({
      signatureState: 'verified',
      feedFreshness: 'fresh',
      feedAgeSeconds: 42,
      packageChannel: 'deb',
      channelInfo: { owner: 'apt/dpkg', installMode: 'package-manager-guided' },
      compatibility: { state: 'aligned', daemonVersion: '1.0.0' }
    });
  });

  it('rejects unsupported freshness, channel, signature, and compatibility states', () => {
    expect(() => decodeLinuxUpdateStatus({
      state: 'current', currentVersion: '1.0.0', feedFreshness: 'ancient'
    })).toThrow('feed freshness');
    expect(() => decodeLinuxUpdateStatus({
      state: 'current', currentVersion: '1.0.0', signatureState: 'forged'
    })).toThrow('signature state');
    expect(() => decodeLinuxUpdateStatus({
      state: 'current', currentVersion: '1.0.0', channelInfo: {
        id: 'deb', label: 'Debian', owner: 'apt/dpkg', installMode: 'shell',
        automaticInstall: false, rollbackMode: 'none', explanation: 'x'
      }
    })).toThrow('package channel metadata');
    expect(() => decodeLinuxUpdateStatus({
      state: 'current', currentVersion: '1.0.0', compatibility: {
        state: 'mismatch', shellVersion: ''
      }
    })).toThrow('compatibility');
  });

  it('accepts package-native actions emitted by Rust, including rollback placeholder', () => {
    const decoded = decodeLinuxUpdateStatus({
      state: 'unavailable',
      currentVersion: '0.1.0',
      instructions: {
        packageManager: 'apt',
        install: {
          id: 'install', label: 'Update with apt', instruction: 'Use apt.',
          command: 'sudo apt-get install --only-upgrade open-burn-bar', available: true, requiresConfirmation: true
        },
        rollback: {
          id: 'rollback', label: 'Roll back with apt', instruction: 'Choose a prior version.',
          command: 'sudo apt-get install --allow-downgrades open-burn-bar=PREVIOUS_VERSION', available: true, requiresConfirmation: true
        },
        restart: {
          id: 'restart', label: 'Restart OpenBurnBar', instruction: 'Restart after replacement.',
          command: 'systemctl --user restart openburnbar-daemon.service', available: true, requiresConfirmation: false
        }
      },
      reason: 'feed unavailable'
    });
    expect(decoded.instructions?.rollback.command).toBe('sudo apt-get install --allow-downgrades open-burn-bar=PREVIOUS_VERSION');
  });

  it('rejects unsafe or incomplete native package actions', () => {
    expect(() => decodeLinuxUpdateStatus({
      state: 'current',
      currentVersion: '0.1.0',
      instructions: {
        packageManager: 'apt',
        install: { id: 'install', label: 'Install', instruction: 'x', command: 'sudo apt; touch /tmp/pwned', available: true, requiresConfirmation: true }
      }
    })).toThrow('package action metadata');
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
