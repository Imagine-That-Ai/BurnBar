import type { ProxyRouteLogEntry } from './tauriBridgeTypes.js';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { bridgeStubDefaults } from './testing/bridgeStubs';
import {
  PROXY_ROUTE_FINAL_STATUS_COPY,
  normalizeProxyRouteFinalStatus,
  mapProxyRouteLog,
  computeCacheHitRatePct,
  decodeUsageInsights,
  decodeChatAttachmentUpload,
  decodeGatewayAttachmentCapability,
  decodeChatMessageAppend,
  decodeChatThreadGet,
  decodeChatThreadList,
  decodeDaemonSubscriptionResponse,
  decodeDaemonSubscriptionStopResponse,
  mapMissionDetail,
  mapMissionHealth,
  mapMissionList,
  mapQuestionList,
  decodeLinuxUpdateStatus,
  decodeNativeNotificationCapabilities,
  decodeNativeNotificationResult,
  decodeNativeNotificationActionEvent,
  decodeNativeNotificationActionEvents,
  decodeNativeShortcutStatus,
  decodeLaunchAtLoginStatus,
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

const INTERRUPTED_FIXTURE_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../docs/linux-port/fixtures/proxy-route-log-interrupted.fixture.json'
);


describe('daemon-owned qualitative insights decoding', () => {
  it('accepts the bounded local-rules result and preserves authority metadata', () => {
    const result = decodeUsageInsights({
      usage: [{
        providerID: 'codex',
        modelID: 'gpt-5',
        inputTokens: 10,
        outputTokens: 5,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        reasoningTokens: 0,
        cost: 0.12,
        recordedAt: ACCOUNT_UPDATED_AT,
        sessionID: 'session-1'
      }],
      sourceID: 'daemon.usage.ledger',
      sourceLabel: 'Linux daemon usage ledger · local rules',
      analysis: {
        requestID: 'request-1',
        generatedAt: ACCOUNT_UPDATED_AT,
        executiveSummary: 'Codex is the main spend driver.',
        modelTag: { displayName: 'Linux local rules' },
        findings: [{
          id: 'finding-1',
          title: 'Codex is the main spend driver',
          whyItMatters: 'It accounts for the included spend.',
          recommendedAction: 'Compare lower-cost routes.',
          evidence: [{ id: 'citation-1', label: 'Codex session' }]
        }],
        citations: [{ id: 'citation-1', label: 'Codex session' }]
      }
    });
    expect(result.source).toMatchObject({ id: 'daemon.usage.insights', kind: 'daemon-method' });
    expect(result.qualitative).toMatchObject({
      state: 'available',
      method: 'daemon.usage.insights',
      sourceID: 'daemon.usage.ledger'
    });
    expect(result.qualitative?.analysis?.findings[0]?.title).toBe('Codex is the main spend driver');
  });

  it('normalizes canonical usage rows while preserving legacy aliases', () => {
    const recent = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
    const priorWeek = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString();
    const result = decodeUsageInsights({
      usage: [
        {
          providerID: 'codex',
          modelID: 'gpt-5',
          inputTokens: 10,
          outputTokens: 5,
          reasoningTokens: 2,
          cost: 0.12,
          recordedAt: recent
        },
        {
          provider: 'anthropic',
          model: 'claude-opus',
          tokens: 23,
          costUsd: 0.34,
          at: priorWeek
        }
      ]
    });

    expect(result.weekly.at(-1)).toMatchObject({ tokens: 17, costUsd: 0.12 });
    expect(result.weekly.at(-2)).toMatchObject({ tokens: 23, costUsd: 0.34 });
    expect(result.weekly.reduce((total, bucket) => total + bucket.tokens, 0)).toBe(40);
    expect(result.providerMix.map((entry) => entry.id)).toEqual(['anthropic', 'codex']);
    expect(result.modelMix.map((entry) => entry.id)).toEqual(['claude-opus', 'gpt-5']);
  });

  it('excludes malformed, future-dated, and invalid-token rows from charts', () => {
    const recent = new Date(Date.now() - 60 * 1000).toISOString();
    const future = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    const result = decodeUsageInsights({
      usage: [
        { providerID: 'valid', modelID: 'valid-model', inputTokens: 7, outputTokens: 3, recordedAt: recent },
        { providerID: 'invalid-date', modelID: 'invalid-date', totalTokens: 1_000, recordedAt: 'not-a-date' },
        { providerID: 'future', modelID: 'future', totalTokens: 2_000, recordedAt: future },
        { providerID: 'negative', modelID: 'negative', inputTokens: 8, outputTokens: -1, recordedAt: recent }
      ]
    });

    expect(result.weekly.reduce((total, bucket) => total + bucket.tokens, 0)).toBe(10);
    expect(result.providerMix).toHaveLength(1);
    expect(result.providerMix[0]).toMatchObject({ id: 'valid', pct: 100 });
    expect(result.modelMix[0]).toMatchObject({ id: 'valid-model', pct: 100 });
  });
});

describe('Linux launch-at-login decoding', () => {
  it('accepts the typed packaged and user override states', () => {
    expect(decodeLaunchAtLoginStatus({
      enabled: false,
      userOverride: true,
      source: 'user',
      path: '/home/alberto/.config/autostart/openburnbar.desktop',
      detail: 'User autostart override disables the packaged entry.'
    })).toMatchObject({ enabled: false, userOverride: true, source: 'user' });
  });

  it('rejects unknown source values and malformed booleans', () => {
    expect(() => decodeLaunchAtLoginStatus({
      enabled: true,
      userOverride: false,
      source: 'shell',
      path: '/home/alberto/.config/autostart/openburnbar.desktop'
    })).toThrow(/source is unsupported/);
    expect(() => decodeLaunchAtLoginStatus({
      enabled: 'yes',
      userOverride: false,
      source: 'packaged',
      path: '/home/alberto/.config/autostart/openburnbar.desktop'
    })).toThrow(/enabled state/);
  });
});

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

describe('gateway attachment capability decoding', () => {
  it('accepts a bounded native capability result', () => {
    expect(decodeGatewayAttachmentCapability({
      mimeType: 'image/png',
      state: 'supported',
      reason: 'catalog',
      maxBytes: 5 * 1024 * 1024
    })).toEqual({
      mimeType: 'image/png',
      state: 'supported',
      reason: 'catalog',
      maxBytes: 5 * 1024 * 1024
    });
  });

  it('accepts audio capability metadata without widening the response shape', () => {
    expect(decodeGatewayAttachmentCapability({
      mimeType: 'audio/mp4',
      state: 'supported',
      reason: 'catalog',
      maxBytes: 2 * 1024 * 1024
    })).toEqual({
      mimeType: 'audio/mp4',
      state: 'supported',
      reason: 'catalog',
      maxBytes: 2 * 1024 * 1024
    });
  });

  it('rejects malformed capability state and unsafe limits', () => {
    expect(() => decodeGatewayAttachmentCapability({
      mimeType: 'image/png',
      state: 'maybe',
      reason: 'catalog'
    })).toThrow('state');
    expect(() => decodeGatewayAttachmentCapability({
      mimeType: 'image/png',
      state: 'supported',
      reason: 'catalog',
      maxBytes: 10 * 1024 * 1024 + 1
    })).toThrow('out of bounds');
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

  it('keeps an empty list honest and rejects incomplete mission snapshots', () => {
    expect(mapMissionList({ missions: [] })).toEqual({ missions: [], pendingApprovals: [] });
    expect(() => mapMissionDetail({
      mission: { id: 'm-degraded', title: 'Unknown', status: 'failed', packets: [] }
    })).toThrow('updatedAt');
  });

  it('fails closed instead of fabricating malformed mission identity and lifecycle state', () => {
    const valid = {
      id: 'm-valid',
      title: 'Valid mission',
      status: 'in_progress',
      updatedAt: '2026-07-20T10:00:00Z',
      packets: []
    };
    expect(() => mapMissionList({})).toThrow('mission list');
    expect(() => mapMissionList({ missions: [{ ...valid, id: '' }] })).toThrow('id');
    expect(() => mapMissionList({ missions: [{ ...valid, status: 'invented' }] })).toThrow('status');
    expect(() => mapMissionList({ missions: [{ ...valid, packets: [{}] }] })).toThrow('packet 0 id');
  });

  it('fails closed on malformed daemon-owned mission health and history', () => {
    const valid = {
      missionID: 'm-health',
      health: {
        status: 'healthy',
        detail: 'One packet is active.',
        checkedAt: '2026-07-20T10:00:00Z',
        lastActivityAt: '2026-07-20T09:59:00Z',
        activePacketCount: 1,
        failedResultCount: 0
      },
      history: []
    };
    expect(() => mapMissionHealth({ ...valid, missionID: '' })).toThrow('missionId');
    expect(() => mapMissionHealth({ ...valid, health: { ...valid.health, status: 'fine' } })).toThrow('status');
    expect(() => mapMissionHealth({
      ...valid,
      health: { ...valid.health, activePacketCount: -1 }
    })).toThrow('activePacketCount');
    expect(() => mapMissionHealth({ ...valid, history: [{}] })).toThrow('history 0 id');
  });

  it('decodes native Swift Foundation-reference mission dates', () => {
    const nativeSeconds = (Date.parse('2026-07-20T10:00:00Z') - Date.UTC(2001, 0, 1)) / 1_000;
    const detail = mapMissionDetail({
      mission: {
        id: 'm-native-date',
        title: 'Native dates',
        status: 'completed',
        createdAt: nativeSeconds,
        updatedAt: nativeSeconds,
        approval: { approved: true, approvedAt: nativeSeconds },
        packets: [{
          id: 'p-native', workerName: 'worker', objective: 'Check dates', status: 'completed',
          dispatchedAt: nativeSeconds, completedAt: nativeSeconds, metadata: {}
        }],
        results: [{
          id: 'r-native', status: 'succeeded', summary: 'Done', burnDelta: 0,
          createdAt: nativeSeconds, evidenceRefs: [], metadata: {}
        }]
      }
    });
    expect(detail).toMatchObject({
      createdAt: '2026-07-20T10:00:00.000Z',
      updatedAt: '2026-07-20T10:00:00.000Z',
      approval: { approvedAt: '2026-07-20T10:00:00.000Z' },
      packets: [{ dispatchedAt: '2026-07-20T10:00:00.000Z' }],
      results: [{ createdAt: '2026-07-20T10:00:00.000Z' }]
    });
  });
});

describe('pending question mapping', () => {
  const question = {
    id: 'q-1',
    projectSlug: 'burnbar',
    title: 'Choose lane',
    prompt: 'Which lane?',
    status: 'pending',
    priority: 'high',
    askedAt: '2026-07-20T10:00:00Z',
    evidenceRefs: ['evidence://lane'],
    suggestedOptions: [{ id: 'safe', title: 'Safe', answer: 'Safe lane', metadata: {} }],
    deepLink: { kind: 'project', targetID: 'burnbar', title: 'Open project', metadata: {} },
    metadata: {}
  };

  it('maps canonical pending questions and answer options', () => {
    expect(mapQuestionList({ questions: [question] })).toEqual([expect.objectContaining({
      id: 'q-1',
      status: 'pending',
      priority: 'high',
      evidenceRefs: ['evidence://lane'],
      suggestedOptions: [{ id: 'safe', title: 'Safe', answer: 'Safe lane' }],
      deepLink: { kind: 'project', targetId: 'burnbar', title: 'Open project', subtitle: undefined }
    })]);
  });

  it('decodes native Swift Foundation-reference question dates', () => {
    const nativeSeconds = (Date.parse('2026-07-20T10:00:00Z') - Date.UTC(2001, 0, 1)) / 1_000;
    expect(mapQuestionList({ questions: [{ ...question, askedAt: nativeSeconds, dueAt: nativeSeconds + 3_600 }] }))
      .toEqual([expect.objectContaining({
        askedAt: '2026-07-20T10:00:00.000Z',
        dueAt: '2026-07-20T11:00:00.000Z'
      })]);
  });

  it('rejects malformed status, timestamps, and unbounded collections', () => {
    expect(() => mapQuestionList({ questions: [{ ...question, status: 'invented' }] })).toThrow('status');
    expect(() => mapQuestionList({ questions: [{ ...question, askedAt: 'yesterday' }] })).toThrow('askedAt');
    expect(() => mapQuestionList({ questions: [{ ...question, evidenceRefs: Array(101).fill('x') }] }))
      .toThrow('at most 100');
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

  it('accepts Arch package metadata and pacman guidance', () => {
    const decoded = decodeLinuxUpdateStatus({
      state: 'available',
      currentVersion: '1.0.0',
      latestVersion: '1.1.0',
      packageChannel: 'arch',
      artifact: {
        type: 'arch',
        architecture: 'x86_64',
        url: 'https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.1.0/openburnbar-1.1.0-x86_64.pkg.tar.zst',
        sha256: 'a'.repeat(64),
        size: 100,
        signatureUrl: 'https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.1.0/openburnbar-1.1.0-x86_64.pkg.tar.zst.sig'
      },
      instructions: {
        packageManager: 'pacman',
        install: {
          id: 'install', label: 'Update with pacman', instruction: 'Use pacman.',
          available: false, requiresConfirmation: true
        },
        rollback: {
          id: 'rollback', label: 'Roll back with pacman', instruction: 'Choose a prior version.',
          available: false, requiresConfirmation: true
        },
        restart: {
          id: 'restart', label: 'Restart OpenBurnBar', instruction: 'Restart after replacement.',
          command: 'systemctl --user restart openburnbar-daemon.service', available: true, requiresConfirmation: false
        }
      },
      channelInfo: {
        id: 'arch',
        label: 'Arch package (.pkg.tar.zst)',
        owner: 'pacman',
        installMode: 'package-manager-guided',
        automaticInstall: false,
        rollbackMode: 'pacman-cache',
        explanation: 'The Arch package manager owns files and upgrades.'
      }
    });
    expect(decoded).toMatchObject({
      packageChannel: 'arch',
      artifact: { type: 'arch', architecture: 'x86_64' },
      instructions: { packageManager: 'pacman' },
      channelInfo: { id: 'arch', owner: 'pacman' }
    });
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
    expect(decodeNativeShortcutStatus({
      available: false,
      registered: false,
      backend: 'wayland',
      shortcuts: ['Ctrl+Alt+Super+Period'],
      portalAvailable: true,
      portalReason: 'native_shortcuts_portal_interface_present_registration_pending',
      bindings: [{ id: 'computer-use-panic', shortcut: 'Ctrl+Alt+Super+Period', state: 'unavailable' }]
    })).toMatchObject({
      backend: 'wayland',
      portalAvailable: true,
      portalReason: 'native_shortcuts_portal_interface_present_registration_pending'
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

  it('strictly decodes the cold-start notification action queue', () => {
    expect(decodeNativeNotificationActionEvents([
      { notificationId: 'n-1', route: 'chat', action: 'reply' }
    ])).toEqual([{ notificationId: 'n-1', route: 'chat', action: 'reply' }]);
    expect(() => decodeNativeNotificationActionEvents({})).toThrow('must be an array');
    expect(() => decodeNativeNotificationActionEvents([
      { notificationId: 'n-2', route: 'unknown', action: 'open' }
    ])).toThrow('unsupported');
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

describe('proxy route log interrupted status (cross-platform contract)', () => {
  it('normalizes every canon wire name and falls back to unknown', () => {
    // Mirrors BurnBarProxyRouteFinalStatus in
    // OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarProxyRouteLogContracts.swift.
    const wireNames = [
      'exact',
      'same_model_failover',
      'cross_vendor_fallback',
      'failed',
      'rejected',
      'interrupted'
    ] as const;
    for (const wireName of wireNames) {
      expect(normalizeProxyRouteFinalStatus(wireName)).toBe(wireName);
    }
    expect(normalizeProxyRouteFinalStatus('brand_new_status')).toBe('unknown');
    expect(normalizeProxyRouteFinalStatus('')).toBe('unknown');
  });

  it('decodes the shared interrupted fixture exactly as the Swift daemon persists it', () => {
    // Same fixture is decoded by OpenBurnBarDaemonTests
    // (BurnBarProxyRouteInterruptedStatusTests) — both sides fail if the wire
    // contract for status `interrupted` drifts.
    const fixture = JSON.parse(readFileSync(INTERRUPTED_FIXTURE_PATH, 'utf8'));
    const entries = mapProxyRouteLog(fixture);
    expect(entries).toHaveLength(1);
    const entry = entries[0];
    expect(entry.finalStatus).toBe('interrupted');
    expect(entry.streamed).toBe(true);
    expect(entry.streamInterrupted).toBe(true);
    expect(entry.failureMessage).toBe('upstream stream interrupted');
    expect(entry.providerName).toBe('Anthropic');
    expect(entry.httpStatus).toBe(200);
  });

  it('renders interrupted with its own retryable copy, distinct from failed', () => {
    expect(PROXY_ROUTE_FINAL_STATUS_COPY.interrupted).toBe('Interrupted — retryable');
    expect(PROXY_ROUTE_FINAL_STATUS_COPY.interrupted).not.toBe(PROXY_ROUTE_FINAL_STATUS_COPY.failed);
    // Every status the contract can produce has human copy (Record is
    // compile-time exhaustive; this guards the runtime values too).
    for (const value of Object.values(PROXY_ROUTE_FINAL_STATUS_COPY)) {
      expect(value.length).toBeGreaterThan(0);
    }
  });

  it('keeps interrupted entries out of the failed bucket when filtering', () => {
    const fixture = JSON.parse(readFileSync(INTERRUPTED_FIXTURE_PATH, 'utf8'));
    const entries = mapProxyRouteLog(fixture);
    expect(entries.filter((e: ProxyRouteLogEntry) => e.finalStatus === 'failed')).toHaveLength(0);
    expect(entries.filter((e: ProxyRouteLogEntry) => e.finalStatus === 'interrupted')).toHaveLength(1);
  });
});
