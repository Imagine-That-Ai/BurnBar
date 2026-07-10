import { describe, expect, it } from 'vitest';
import { bridgeStubDefaults } from './testing/bridgeStubs';
import {
  computeCacheHitRatePct,
  decodeChatMessageAppend,
  decodeChatThreadGet,
  decodeChatThreadList,
  decodeAccountStatus,
  decodeDaemonSubscriptionResponse,
  decodeDaemonSubscriptionStopResponse,
  decodeProviderExternalAuthFlow,
  decodeNativeDeepLink,
  decodeNativeNotificationCapabilities,
  decodeNativeNotificationResult,
  decodeNativeShellSnapshot,
  decodeNativeStatusSnapshot,
  decodeNativeTraySnapshot
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

function providerExternalAuthResponse(flow: Record<string, unknown>) {
  return {
    flow: {
      flowID: null,
      providerID: 'openai',
      providerDisplayName: 'OpenAI',
      authMethodID: 'openai-codex-oauth',
      authMethodDisplayName: 'Sign in with ChatGPT',
      cliDisplayName: 'Codex',
      state: 'idle',
      availability: 'available',
      cliInstalled: true,
      connected: false,
      accountDescription: null,
      problem: null,
      startedAt: null,
      updatedAt: ACCOUNT_UPDATED_AT,
      expiresAt: null,
      completedAt: null,
      ...flow
    }
  };
}

describe('provider external auth wire decoding', () => {
  it('strictly decodes a registry-backed active flow', () => {
    expect(decodeProviderExternalAuthFlow(providerExternalAuthResponse({
      flowID: 'provider-flow-1',
      state: 'awaiting_user',
      startedAt: ACCOUNT_UPDATED_AT,
      expiresAt: '2026-07-10T12:05:00Z'
    }))).toMatchObject({
      flowId: 'provider-flow-1',
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth',
      state: 'awaiting_user',
      cliInstalled: true
    });
  });

  it('drops injected credentials, terminal output, paths, and callback material', () => {
    const decoded = decodeProviderExternalAuthFlow(providerExternalAuthResponse({
      token: 'oauth-secret',
      terminalOutput: 'callback-secret',
      executablePath: '/secret/codex',
      configDirectory: '/secret/config',
      callbackURL: 'http://127.0.0.1/?code=secret'
    }));
    expect(JSON.stringify(decoded)).not.toMatch(/oauth-secret|callback-secret|\/secret|127\.0\.0\.1/);
  });

  it('accepts a sanitized preflight failure without inventing a flow', () => {
    expect(decodeProviderExternalAuthFlow(providerExternalAuthResponse({
      state: 'failed',
      availability: 'unavailable',
      cliInstalled: false,
      problem: {
        code: 'executable_not_found',
        message: 'Codex is not installed.',
        recoverable: true
      }
    }))).toMatchObject({
      state: 'failed',
      flowId: undefined,
      problem: { code: 'executable_not_found' }
    });
  });

  it('rejects malformed lifecycle combinations and unknown problem codes', () => {
    expect(() => decodeProviderExternalAuthFlow(providerExternalAuthResponse({
      flowID: null,
      state: 'awaiting_user'
    }))).toThrow('flowID');
    expect(() => decodeProviderExternalAuthFlow(providerExternalAuthResponse({
      state: 'succeeded',
      flowID: 'provider-flow-1',
      startedAt: ACCOUNT_UPDATED_AT,
      completedAt: ACCOUNT_UPDATED_AT,
      connected: false
    }))).toThrow('connected');
    expect(() => decodeProviderExternalAuthFlow(providerExternalAuthResponse({
      problem: { code: 'raw_oauth_error', message: 'secret', recoverable: true }
    }))).toThrow('problem.code');
  });
});

function accountResponse(account: Record<string, unknown>) {
  return {
    account: {
      state: 'signed_out',
      uid: null,
      email: null,
      display_name: null,
      photo_url: null,
      trust_class: 'linux_lower_trust',
      sync_state: 'local_only',
      credential_backend: null,
      session: null,
      problem: null,
      updated_at: ACCOUNT_UPDATED_AT,
      ...account
    }
  };
}

describe('account wire decoding', () => {
  it('strictly decodes a pending desktop auth session without exposing credentials', () => {
    expect(decodeAccountStatus(accountResponse({
      state: 'authorization_pending',
      session: {
        flow_id: 'flow-1',
        user_code: 'ABCD-EFGH',
        verification_url: 'https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH',
        expires_at: '2026-07-10T12:10:00Z',
        poll_interval_seconds: 5
      }
    }))).toMatchObject({
      state: 'authorization_pending',
      signedIn: false,
      session: { flowId: 'flow-1', userCode: 'ABCD-EFGH', pollIntervalSeconds: 5 }
    });
  });

  it('decodes signed-in identity and derives a safe display label', () => {
    expect(decodeAccountStatus(accountResponse({
      state: 'signed_in',
      uid: 'user-1',
      email: 'user@example.com',
      display_name: 'User',
      sync_state: 'active',
      credential_backend: 'org.freedesktop.secrets'
    }))).toMatchObject({
      signedIn: true,
      identityLabel: 'User',
      syncState: 'active',
      credentialBackend: 'org.freedesktop.secrets'
    });
  });

  it('drops every injected credential field at the renderer boundary', () => {
    const decoded = decodeAccountStatus(accountResponse({
      state: 'signed_in',
      uid: 'user-1',
      id_token: 'id-secret',
      refresh_token: 'refresh-secret',
      firebase_custom_token: 'custom-secret',
      credentialEnvelope: { ciphertextBase64: 'sealed-secret' }
    }));
    const serialized = JSON.stringify(decoded);
    expect(serialized).not.toContain('id-secret');
    expect(serialized).not.toContain('refresh-secret');
    expect(serialized).not.toContain('custom-secret');
    expect(serialized).not.toContain('sealed-secret');
  });

  it('rejects invented states, missing pending sessions, and noncanonical auth URLs', () => {
    expect(() => decodeAccountStatus(accountResponse({ state: 'expired' }))).toThrow('state');
    expect(() => decodeAccountStatus(accountResponse({ state: 'authorization_pending' }))).toThrow('session');
    expect(() => decodeAccountStatus(accountResponse({
      state: 'authorization_pending',
      session: {
        flow_id: 'flow-1',
        user_code: 'ABCD-EFGH',
        verification_url: 'https://burnbar.ai.evil.example/link?flow=desktop_auth',
        expires_at: '2026-07-10T12:10:00Z',
        poll_interval_seconds: 5
      }
    }))).toThrow('desktop auth boundary');
  });

  it.each([
    ['missing code', 'ABCD-EFGH', 'https://burnbar.ai/link?flow=desktop_auth'],
    ['extra query item', 'ABCD-EFGH', 'https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH&next=account'],
    ['duplicate code', 'ABCD-EFGH', 'https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH&code=JKMN-PQRS'],
    ['malformed code', 'ABCI-EFGH', 'https://burnbar.ai/link?flow=desktop_auth&code=ABCI-EFGH'],
    ['mismatched code', 'ABCD-EFGH', 'https://burnbar.ai/link?flow=desktop_auth&code=JKMN-PQRS']
  ])('rejects a %s desktop auth URL', (_case, userCode, verificationUrl) => {
    expect(() => decodeAccountStatus(accountResponse({
      state: 'authorization_pending',
      session: {
        flow_id: 'flow-1',
        user_code: userCode,
        verification_url: verificationUrl,
        expires_at: '2026-07-10T12:10:00Z',
        poll_interval_seconds: 5
      }
    }))).toThrow(/canonical|matching/);
  });

  it('decodes only the frozen account problem codes', () => {
    expect(decodeAccountStatus(accountResponse({
      problem: {
        code: 'authorization_expired',
        message: 'Start again.',
        recoverable: true
      }
    })).problem).toEqual({ code: 'authorization_expired', message: 'Start again.', recoverable: true });
    expect(() => decodeAccountStatus(accountResponse({
      problem: { code: 'other', message: 'No', recoverable: false }
    }))).toThrow('problem.code');
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

  it('strictly decodes the compact status snapshot and tray bounds', () => {
    expect(decodeNativeStatusSnapshot({
      shell: {
        loginStartEnabled: false,
        loginStartPath: '/home/alice/.config/autostart/dev.openburnbar.OpenBurnBar.desktop',
        backgroundLaunch: true,
        rejectedDeepLinks: 1
      },
      tray: {
        todayCostUsd: 7.5,
        todayTokens: 4096,
        connectedProviders: 2,
        quotaFloorRemainingPercent: 33,
        freshness: 'live'
      }
    })).toMatchObject({
      tray: { todayCostUsd: 7.5, freshness: 'live' },
      shell: { backgroundLaunch: true }
    });
    expect(() => decodeNativeTraySnapshot({
      todayCostUsd: 1,
      todayTokens: 1,
      connectedProviders: 2_000,
      freshness: 'live'
    })).toThrow('connectedProviders');
  });

  it('decodes notification capabilities and delivery result without accepting malformed fields', () => {
    expect(decodeNativeNotificationCapabilities({
      available: true,
      actions: true,
      persistence: false,
      body: true,
      bodyMarkup: false,
      serverCapabilities: ['actions', 'body']
    })).toMatchObject({ available: true, actions: true });
    expect(decodeNativeNotificationResult({
      notificationId: 'agent-reply-1',
      delivered: true,
      actionsAttached: true,
      degradedReason: null
    })).toEqual({
      notificationId: 'agent-reply-1',
      delivered: true,
      actionsAttached: true,
      degradedReason: undefined
    });
    expect(() => decodeNativeNotificationCapabilities({
      available: true,
      actions: true,
      persistence: false,
      body: true,
      bodyMarkup: false,
      serverCapabilities: [42]
    })).toThrow('serverCapabilities');
  });
});
