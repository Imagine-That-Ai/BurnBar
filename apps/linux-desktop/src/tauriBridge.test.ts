import { describe, expect, it } from 'vitest';
import { bridgeStubDefaults } from './testing/bridgeStubs';
import {
  computeCacheHitRatePct,
  decodeChatAttachmentUpload,
  decodeChatMessageAppend,
  decodeChatThreadGet,
  decodeChatThreadList,
  decodeDaemonSubscriptionResponse,
  decodeDaemonSubscriptionStopResponse,
  mapMissionDetail,
  mapMissionList,
  decodeLinuxUpdateStatus,
  decodeNativeNotificationCapabilities,
  decodeNativeNotificationResult,
  decodeNativeNotificationActionEvent,
  decodeNativeShortcutStatus,
  decodePetCompanionStatus
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

describe('chat attachment upload decoding', () => {
  it('accepts bounded daemon-owned metadata without exposing a path', () => {
    expect(decodeChatAttachmentUpload({
      attachmentId: 'attachment-1',
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      byteSize: 12,
      sha256: 'a'.repeat(64)
    })).toEqual({
      attachmentId: 'attachment-1',
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      byteSize: 12,
      sha256: 'a'.repeat(64)
    });
  });

  it('rejects unsupported types, oversized metadata, and path leakage', () => {
    expect(() => decodeChatAttachmentUpload({
      attachmentId: 'attachment-1',
      fileName: 'notes.exe',
      mimeType: 'application/x-msdownload',
      byteSize: 12,
      sha256: 'a'.repeat(64)
    })).toThrow('unsupported');
    expect(() => decodeChatAttachmentUpload({
      attachmentId: 'attachment-1',
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      byteSize: 10 * 1024 * 1024 + 1,
      sha256: 'a'.repeat(64)
    })).toThrow('between');
    expect(() => decodeChatAttachmentUpload({
      attachmentId: 'attachment-1',
      fileName: '/tmp/notes.md',
      mimeType: 'text/markdown',
      byteSize: 12,
      sha256: 'a'.repeat(64),
      path: '/home/alberto/secret'
    })).toThrow('path');
  });
});

describe('mission snapshot mapping', () => {
  it('maps canonical packet, result, evidence, approval and takeover fields', () => {
    const detail = mapMissionDetail({
      mission: {
        id: 'm-1',
        projectSlug: 'burnbar',
        title: 'Ship parity',
        summary: 'Close the Linux mission gap.',
        status: 'in_progress',
        recommendation: 'review',
        createdAt: '2026-07-13T10:00:00Z',
        updatedAt: new Date().toISOString(),
        approval: { approved: true, approvedAt: '2026-07-13T10:01:00Z', approvedBy: 'alberto', note: 'go' },
        packets: [{
          id: 'p-1', missionID: 'm-1', workerName: 'worker-a', objective: 'Implement UI', status: 'completed',
          runID: 'run-1', dispatchedAt: '2026-07-13T10:02:00Z', completedAt: '2026-07-13T10:03:00Z', metadata: { source: 'daemon' }
        }],
        results: [{
          id: 'r-1', missionID: 'm-1', packetID: 'p-1', runID: 'run-1', status: 'succeeded',
          summary: 'UI landed', detail: 'Verified', burnDelta: 1.5, createdAt: '2026-07-13T10:04:00Z',
          evidenceRefs: ['evidence/mission.json'], metadata: {}
        }],
        burnRecords: [{ id: 'b-1', label: 'Tokens', amount: 12, unit: 'tokens', recordedAt: '2026-07-13T10:04:00Z' }],
        takeoverHistory: [{
          id: 't-1', projectSlug: 'burnbar', missionID: 'm-1', status: 'completed', reason: 'recovered',
          createdAt: '2026-07-13T10:05:00Z', updatedAt: '2026-07-13T10:06:00Z', metadata: {}
        }],
        metadata: { source: 'test' }
      }
    });
    expect(detail).toMatchObject({
      id: 'm-1', state: 'in_progress', laneCount: 1, recommendation: 'review', freshness: 'fresh',
      approval: { approved: true, approvedBy: 'alberto' },
      packets: [{ id: 'p-1', missionId: 'm-1', runId: 'run-1' }],
      results: [{ id: 'r-1', evidenceRefs: ['evidence/mission.json'] }],
      takeoverHistory: [{ id: 't-1', missionId: 'm-1' }]
    });
  });

  it('derives pending approval only from canonical awaiting-approval snapshots', () => {
    const list = mapMissionList({
      missions: [{
        id: 'm-awaiting', title: 'Needs review', summary: 'Ask for approval', status: 'awaiting_approval',
        createdAt: '2026-07-13T09:00:00Z', updatedAt: '2026-07-13T09:00:00Z', approval: { approved: false }, packets: []
      }, {
        id: 'm-approved', title: 'Approved', status: 'approved', updatedAt: '2026-07-13T09:00:00Z',
        approval: { approved: true }, packets: []
      }]
    });
    expect(list.pendingApprovals).toEqual([expect.objectContaining({ missionId: 'm-awaiting', risk: 'standard' })]);
  });

  it('keeps empty and degraded snapshots honest', () => {
    expect(mapMissionList({ missions: [] })).toEqual({ missions: [], pendingApprovals: [] });
    const degraded = mapMissionDetail({ mission: { id: 'm-degraded', title: 'Unknown', status: 'failed', packets: [] } });
    expect(degraded).toMatchObject({ id: 'm-degraded', freshness: 'unknown', packets: [], results: [], takeoverHistory: [] });
  });
});

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

describe('native Linux notification and shortcut decoding', () => {
  it('keeps freedesktop capability and degraded action state explicit', () => {
    expect(decodeNativeNotificationCapabilities({
      available: true,
      actions: false,
      persistence: true,
      body: true,
      bodyMarkup: false,
      serverCapabilities: ['body', 'persistence'],
      degradedReason: 'native_notification_actions_unavailable'
    })).toMatchObject({ available: true, actions: false, degradedReason: 'native_notification_actions_unavailable' });
    expect(decodeNativeNotificationResult({
      notificationId: 'linux-native-1',
      delivered: true,
      actionsAttached: false,
      degradedReason: 'native_notification_actions_unavailable'
    })).toMatchObject({ delivered: true, actionsAttached: false });
  });

  it('rejects unknown notification routes/actions and malformed shortcut status', () => {
    expect(() => decodeNativeNotificationActionEvent({
      notificationId: 'n-1', route: 'admin', action: 'open'
    })).toThrow('unsupported');
    expect(() => decodeNativeNotificationActionEvent({
      notificationId: 'n-1', route: 'chat', action: 'dismiss'
    })).toThrow('unsupported');
    expect(decodeNativeNotificationActionEvent({
      notificationId: 'n-1', route: 'chat', action: 'reply'
    })).toMatchObject({ notificationId: 'n-1', route: 'chat', action: 'reply' });
    expect(decodeNativeShortcutStatus({
      available: false,
      registered: false,
      shortcuts: ['Ctrl+Alt+Super+O'],
      degradedReason: 'native_shortcuts_not_initialized'
    })).toMatchObject({ registered: false, degradedReason: 'native_shortcuts_not_initialized' });
    expect(decodeNativeShortcutStatus({
      available: true,
      registered: false,
      backend: 'x11',
      shortcuts: ['Ctrl+Alt+Super+Period', 'Ctrl+Alt+Super+O'],
      bindings: [
        { id: 'computer-use-panic', shortcut: 'Ctrl+Alt+Super+Period', state: 'registered' },
        { id: 'open-dashboard', shortcut: 'Ctrl+Alt+Super+O', state: 'degraded', degradedReason: 'conflict' }
      ],
      degradedReason: 'native_shortcuts_partial_registration'
    })).toMatchObject({
      backend: 'x11',
      available: true,
      registered: false,
      bindings: [{ state: 'registered' }, { state: 'degraded', degradedReason: 'conflict' }]
    });
    expect(() => decodeNativeShortcutStatus({
      available: false,
      registered: false,
      backend: 'mir',
      shortcuts: []
    })).toThrow('backend');
    expect(() => decodeNativeShortcutStatus({
      available: false,
      registered: false,
      shortcuts: [],
      bindings: [{ id: 'open-dashboard', shortcut: 'Ctrl+Alt+Super+O', state: 'active' }]
    })).toThrow('binding state');
    expect(() => decodeNativeShortcutStatus({ available: true, registered: 'yes', shortcuts: [] }))
      .toThrow('registration');
  });

  it('decodes the normalized second-instance notification envelope and rejects non-object payloads', () => {
    expect(decodeNativeNotificationActionEvent({
      notificationId: 'single-instance-chat',
      route: 'chat',
      action: 'open',
      payload: { threadId: 'thread-42' }
    })).toMatchObject({
      notificationId: 'single-instance-chat',
      route: 'chat',
      action: 'open',
      payload: { threadId: 'thread-42' }
    });
    expect(() => decodeNativeNotificationActionEvent({
      notificationId: 'single-instance-chat',
      route: 'chat',
      action: 'open',
      payload: 'thread-42'
    })).toThrow('payload');
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

describe('pet companion wire decoding', () => {
  it('accepts the explicit X11 native-window contract', () => {
    expect(decodePetCompanionStatus({
      state: 'available',
      compositor: 'GNOME/x11',
      sessionType: 'x11',
      desktop: 'GNOME',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'tauri-x11-companion-v1',
      reason: 'ready',
      source: 'tauri-x11-companion-window'
    })).toMatchObject({
      state: 'available',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'tauri-x11-companion-v1'
    });
  });

  it('rejects malformed or unknown native-window states', () => {
    expect(() => decodePetCompanionStatus({
      state: 'maybe', compositor: 'x11', overlaySupported: false, clickThroughSupported: false,
      windowContract: 'none', reason: 'bad', source: 'test'
    })).toThrow(/state is unsupported/);
    expect(() => decodePetCompanionStatus({
      state: 'degraded', compositor: 'x11', overlaySupported: false, clickThroughSupported: false,
      windowContract: 'none', reason: 'bad'
    })).toThrow(/source/);
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
