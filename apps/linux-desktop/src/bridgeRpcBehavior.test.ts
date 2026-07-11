/**
 * VAL-RPC-002 behavioral suite for Phase 2 bridge methods.
 * Exercises invoke mapping via mocked @tauri-apps/api/core (no real daemon).
 */
// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const invoke = vi.fn();

vi.mock('@tauri-apps/api/core', () => ({
  invoke: (...args: unknown[]) => invoke(...args)
}));

vi.mock('@tauri-apps/plugin-shell', () => ({
  open: vi.fn()
}));

describe('VAL-RPC-002 bridge behavior', () => {
  beforeEach(() => {
    invoke.mockReset();
    (window as unknown as { __TAURI_INTERNALS__: object }).__TAURI_INTERNALS__ = {};
  });

  afterEach(() => {
    delete (window as unknown as { __TAURI_INTERNALS__?: object }).__TAURI_INTERNALS__;
  });

  async function bridge() {
    const { loadShellBridge } = await import('./tauriBridge.js');
    const b = await loadShellBridge();
    if (!b) throw new Error('expected tauri bridge');
    return b;
  }

  const pendingAccountResponse = {
    account: {
      state: 'authorization_pending',
      uid: null,
      email: null,
      display_name: null,
      photo_url: null,
      trust_class: 'linux_lower_trust',
      sync_state: 'local_only',
      credential_backend: null,
      session: {
        flow_id: 'flow-1',
        user_code: 'ABCD-EFGH',
        verification_url: 'https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH',
        expires_at: '2026-07-10T12:10:00Z',
        poll_interval_seconds: 5
      },
      problem: null,
      updated_at: '2026-07-10T12:00:00Z'
    }
  };

  const providerExternalAuthResponse = {
    flow: {
      flowID: 'provider-flow-1',
      providerID: 'openai',
      providerDisplayName: 'OpenAI',
      authMethodID: 'openai-codex-oauth',
      authMethodDisplayName: 'Sign in with ChatGPT',
      cliDisplayName: 'Codex',
      state: 'awaiting_user',
      availability: 'available',
      cliInstalled: true,
      connected: false,
      accountDescription: null,
      problem: null,
      startedAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:00:00Z',
      expiresAt: '2026-07-10T12:05:00Z',
      completedAt: null
    }
  };

  it('provider external auth maps the frozen native commands without exposing raw daemon data', async () => {
    invoke.mockResolvedValue(providerExternalAuthResponse);
    const b = await bridge();
    await expect(b.providerExternalAuthStatus?.({ providerId: 'openai' })).resolves.toMatchObject({
      state: 'awaiting_user'
    });
    await b.providerExternalAuthStart?.({
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth'
    });
    await b.providerExternalAuthCancel?.('provider-flow-1');
    expect(invoke).toHaveBeenNthCalledWith(1, 'provider_external_auth_status', {
      providerId: 'openai',
      authMethodId: null,
      flowId: null
    });
    expect(invoke).toHaveBeenNthCalledWith(2, 'provider_external_auth_start', {
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth'
    });
    expect(invoke).toHaveBeenNthCalledWith(3, 'provider_external_auth_cancel', {
      flowId: 'provider-flow-1'
    });
  });

  it('account device auth maps the frozen native command and flow_id boundary', async () => {
    invoke.mockResolvedValue(pendingAccountResponse);
    const b = await bridge();
    await expect(b.accountDeviceAuthStart?.()).resolves.toMatchObject({ state: 'authorization_pending' });
    await expect(b.accountDeviceAuthPoll?.('flow-1')).resolves.toMatchObject({ state: 'authorization_pending' });
    await expect(b.accountDeviceAuthCancel?.('flow-1')).resolves.toMatchObject({ state: 'authorization_pending' });
    expect(invoke).toHaveBeenNthCalledWith(1, 'account_device_auth_start');
    expect(invoke).toHaveBeenNthCalledWith(2, 'account_device_auth_poll', { flowId: 'flow-1' });
    expect(invoke).toHaveBeenNthCalledWith(3, 'account_device_auth_cancel', { flowId: 'flow-1' });
  });

  it('account status, sign-out, and browser open use dedicated native commands', async () => {
    invoke.mockResolvedValueOnce({
      account: {
        ...pendingAccountResponse.account,
        state: 'signed_out',
        session: null
      }
    });
    invoke.mockResolvedValueOnce({
      account: {
        ...pendingAccountResponse.account,
        state: 'signed_out',
        session: null
      }
    });
    invoke.mockResolvedValueOnce(undefined);
    const b = await bridge();
    await b.accountStatus();
    await b.accountSignOut?.();
    await b.openAccountAuthUrl?.('https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH');
    expect(invoke).toHaveBeenNthCalledWith(1, 'account_status');
    expect(invoke).toHaveBeenNthCalledWith(2, 'account_sign_out');
    expect(invoke).toHaveBeenNthCalledWith(3, 'open_account_auth_url', {
      url: 'https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH'
    });
  });

  it('runtimeCapabilities invokes and validates the native manifest', async () => {
    const { makeAvailableRuntimeCapabilityManifest } = await import('./testing/bridgeStubs.js');
    const manifest = makeAvailableRuntimeCapabilityManifest();
    invoke.mockResolvedValueOnce(manifest);
    const b = await bridge();
    await expect(b.runtimeCapabilities()).resolves.toEqual(manifest);
    expect(invoke).toHaveBeenCalledWith('runtime_capabilities');
  });

  it('runtimeCapabilities rejects malformed native data', async () => {
    invoke.mockResolvedValueOnce({ schemaVersion: 1, capabilities: [] });
    const b = await bridge();
    await expect(b.runtimeCapabilities()).rejects.toThrow(/missing_ids/);
  });

  it('toolApprovalRespond success path invokes tool_approval_respond', async () => {
    invoke.mockResolvedValueOnce({ ok: true });
    const b = await bridge();
    await b.toolApprovalRespond?.('appr-1', 'approve', 'lgtm');
    expect(invoke).toHaveBeenCalledWith('tool_approval_respond', {
      approvalId: 'appr-1',
      decision: 'approve',
      note: 'lgtm'
    });
  });

  it('toolApprovalRespond daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('Connection refused'));
    const b = await bridge();
    await expect(b.toolApprovalRespond?.('appr-1', 'reject')).rejects.toThrow(/Connection refused/);
  });

  it('memorySetStatus reject maps to memory_set_status', async () => {
    invoke.mockResolvedValueOnce({ ok: true });
    const b = await bridge();
    await b.memorySetStatus?.('reject', { memoryID: 'm-1' });
    expect(invoke).toHaveBeenCalledWith('memory_set_status', {
      action: 'reject',
      payload: { memoryID: 'm-1' }
    });
  });

  it('memorySetStatus approve with body succeeds', async () => {
    invoke.mockResolvedValueOnce({ memoryID: 'new' });
    const b = await bridge();
    await b.memorySetStatus?.('approve', { text: 'User prefers dark mode' });
    expect(invoke).toHaveBeenCalledWith('memory_set_status', {
      action: 'approve',
      payload: { text: 'User prefers dark mode' }
    });
  });

  it('memoryReviewDecision approve fails closed without inventing text', async () => {
    const b = await bridge();
    await expect(b.memoryReviewDecision('m-1', 'approved')).rejects.toThrow(/without body text/);
    expect(invoke).not.toHaveBeenCalled();
  });

  it('computerUseSessionStart maps contract fields including the bound agent run', async () => {
    invoke.mockResolvedValueOnce({ sessionId: 's1' });
    const b = await bridge();
    await b.computerUseSessionStart?.({
      mode: 'browser',
      trustMode: 'step',
      clientId: 'linux-shell',
      runId: 'run-1',
      runCallId: 'call-1',
      runGeneration: 7
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_session_start', {
      params: {
        mode: 'browser',
        trustMode: 'step',
        clientId: 'linux-shell',
        runId: 'run-1',
        runCallId: 'call-1',
        runGeneration: 7
      }
    });
  });

  it('computerUseInvoke maps nested invocation object', async () => {
    invoke.mockResolvedValueOnce({ status: 'executed' });
    const b = await bridge();
    await b.computerUseInvoke?.({
      sessionId: 's1',
      invocation: {
        callID: 'c1',
        runID: 'r1',
        tool: 'browser_click',
        arguments: { x: 1 },
        requestedBy: 'linux-shell'
      }
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_invoke', {
      params: {
        sessionId: 's1',
        invocation: {
          callID: 'c1',
          runID: 'r1',
          tool: 'browser_click',
          arguments: { x: 1 },
          requestedBy: 'linux-shell'
        }
      }
    });
  });

  it('computerUseApprovalPending maps sessionId only', async () => {
    invoke.mockResolvedValueOnce({ requests: [] });
    const b = await bridge();
    await b.computerUseApprovalPending?.({ sessionId: 's1' });
    expect(invoke).toHaveBeenCalledWith('computer_use_approval_pending', {
      params: { sessionId: 's1' }
    });
  });

  it('computerUseApprovalRespond maps nested response shape', async () => {
    invoke.mockResolvedValueOnce({ accepted: true });
    const b = await bridge();
    await b.computerUseApprovalRespond?.({
      sessionId: 's1',
      approvalId: 'a1',
      decision: 'approve',
      note: 'ok'
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_approval_respond', {
      params: {
        sessionId: 's1',
        approvalId: 'a1',
        decision: 'approve',
        note: 'ok'
      }
    });
  });

  it('computerUsePanicHalt maps source (not reason)', async () => {
    invoke.mockResolvedValueOnce({ ok: true });
    const b = await bridge();
    await b.computerUsePanicHalt?.({ sessionId: 's1', source: 'hotkey' });
    expect(invoke).toHaveBeenCalledWith('computer_use_panic_halt', {
      sessionId: 's1',
      source: 'hotkey'
    });
  });

  it('computerUseAuditExport maps includeScreenshots/anchorOpenTimestamps', async () => {
    invoke.mockResolvedValueOnce({ archiveURL: '/tmp/x.tgz' });
    const b = await bridge();
    await b.computerUseAuditExport?.({
      sessionId: 's1',
      includeScreenshots: false,
      anchorOpenTimestamps: true
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_audit_export', {
      params: {
        sessionId: 's1',
        includeScreenshots: false,
        anchorOpenTimestamps: true
      }
    });
  });

  it('computerUsePanicHalt daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(b.computerUsePanicHalt?.({ sessionId: 's1', source: 'hotkey' })).rejects.toThrow(
      /daemon down/
    );
  });

  it('computerUseInvoke daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(
      b.computerUseInvoke?.({
        sessionId: 's1',
        invocation: { callID: 'c', runID: 'r', tool: 'browser_click', arguments: {} }
      })
    ).rejects.toThrow(/daemon down/);
  });

  it('computerUseAuditExport daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(b.computerUseAuditExport?.({ sessionId: 's1' })).rejects.toThrow(/daemon down/);
  });

  it('computerUseSessionStart daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(
      b.computerUseSessionStart?.({ mode: 'browser', trustMode: 'manual' })
    ).rejects.toThrow(/daemon down/);
  });

  it('computerUseApprovalPending daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(b.computerUseApprovalPending?.({ sessionId: 's1' })).rejects.toThrow(/daemon down/);
  });

  it('computerUseApprovalRespond daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(
      b.computerUseApprovalRespond?.({ approvalId: 'a1', decision: 'reject' })
    ).rejects.toThrow(/daemon down/);
  });

  it('mediaStatus returns capability-absent payload', async () => {
    invoke.mockResolvedValueOnce({
      capabilityAvailable: false,
      pairedDevices: []
    });
    const b = await bridge();
    const status = await b.mediaStatus();
    expect(status.capabilityAvailable).toBe(false);
    expect(status.pairedDevices).toEqual([]);
  });

  it('mediaStatus decodes the daemon capability, session, and nested peer contract', async () => {
    invoke.mockResolvedValueOnce({
      capability: {
        platform: 'linux',
        available: true,
        codecsKnown: true,
        source: 'COpenBurnBarMediaCapture.media_capability_probe'
      },
      session: {
        phase: 'streaming',
        kind: 'mirror',
        requestID: 'mirror-1',
        peer: {
          connectionID: 'phone-1',
          displayName: 'Alberto iPhone',
          isOnline: true,
          lastSeenAt: '2026-07-10T00:00:00Z',
          capabilities: ['mirror.viewer', 'file.receive']
        },
        startedAt: '2026-07-10T00:00:01Z'
      }
    });
    const b = await bridge();
    await expect(b.mediaStatus()).resolves.toEqual({
      capabilityAvailable: true,
      pairedDevices: [
        {
          id: 'phone-1',
          name: 'Alberto iPhone',
          platform: 'unknown',
          isOnline: true,
          lastSeenAt: '2026-07-10T00:00:00Z',
          capabilities: ['mirror.viewer', 'file.receive']
        }
      ],
      activeSession: {
        kind: 'screen-share',
        state: 'active',
        peer: 'Alberto iPhone',
        requestId: 'mirror-1',
        startedAt: '2026-07-10T00:00:01Z'
      }
    });
  });

  it('mediaStatus fails closed when the nested daemon capability is unavailable', async () => {
    invoke.mockResolvedValueOnce({
      capability: {
        available: false,
        codecsKnown: false,
        source: 'MercuryLinuxCapabilityProbe.stub',
        detail: 'XDG_RUNTIME_DIR is not set.'
      },
      session: { phase: 'idle', updatedAt: '2026-07-10T00:00:00Z' }
    });
    const b = await bridge();
    await expect(b.mediaStatus()).resolves.toEqual({
      capabilityAvailable: false,
      pairedDevices: [],
      activeSession: undefined
    });
  });

  it('mediaStatus fails closed when the daemon omits the required availability field', async () => {
    invoke.mockResolvedValueOnce({
      capability: {
        codecsKnown: true,
        source: 'COpenBurnBarMediaCapture.media_capability_probe'
      },
      session: { phase: 'idle', updatedAt: '2026-07-10T00:00:00Z' }
    });
    const b = await bridge();
    await expect(b.mediaStatus()).resolves.toMatchObject({
      capabilityAvailable: false,
      activeSession: undefined
    });
  });

  it('mediaCapabilityGet maps the native media probe to actionable shell support', async () => {
    invoke.mockResolvedValueOnce({
      available: true,
      codecsKnown: true,
      supportsDaemonToShellFrames: true,
      source: 'COpenBurnBarMediaCapture.media_capability_probe',
      detail: 'VP9 capture is ready.'
    });
    const b = await bridge();
    await expect(b.mediaCapabilityGet()).resolves.toEqual({
      available: true,
      renderer: 'media-gst',
      canReceiveCalls: true,
      canViewScreenShare: true,
      reason: 'VP9 capture is ready.'
    });
  });

  it('mediaCapabilityGet fails closed when the probe omits availability', async () => {
    invoke.mockResolvedValueOnce({
      codecsKnown: true,
      supportsDaemonToShellFrames: true,
      source: 'COpenBurnBarMediaCapture.media_capability_probe'
    });
    const b = await bridge();
    await expect(b.mediaCapabilityGet()).resolves.toEqual({
      available: false,
      renderer: 'media-gst',
      canReceiveCalls: false,
      canViewScreenShare: false,
      reason: undefined
    });
  });
});

/**
 * Shared fixture shapes mirroring Rust computer_use_* builders in lib.rs.
 * Keep in sync with BurnBarComputerUseContracts + Tauri command serialization.
 */
export const cuSessionStartFixture = (overrides: Record<string, unknown> = {}) => ({
  mode: 'browser',
  trustMode: 'manual',
  scopeRuleIds: [] as string[],
  phoneViewerNodeId: null as string | null,
  macHostNodeId: null as string | null,
  actionCap: 50,
  sessionTimeoutSeconds: 1800,
  clientID: 'linux-shell',
  runID: null as string | null,
  ...overrides
});

export const cuInvokeFixture = (overrides: Record<string, unknown> = {}) => ({
  sessionId: 's',
  invocation: {
    callID: 'c',
    runID: 'r',
    tool: 'browser_click',
    arguments: {} as Record<string, unknown>,
    requestedBy: 'linux-shell',
    requestedAt: 123.4
  },
  ...overrides
});

export const cuApprovalRespondFixture = (overrides: Record<string, unknown> = {}) => ({
  sessionId: 's',
  // Shell accepts flat approvalId/decision and Rust nests under response.
  approvalId: 'a',
  decision: 'approve',
  note: null as string | null,
  ...overrides
});

export const cuPanicHaltFixture = (overrides: Record<string, unknown> = {}) => ({
  sessionId: 's',
  source: 'hotkey',
  ...overrides
});

describe('Computer Use wire-shape goldens (shared fixtures)', () => {
  it('session.start fixture keys match BurnBarComputerUseContracts', () => {
    const body = cuSessionStartFixture();
    expect(Object.keys(body).sort()).toEqual(
      [
        'actionCap',
        'clientID',
        'macHostNodeId',
        'mode',
        'phoneViewerNodeId',
        'runID',
        'scopeRuleIds',
        'sessionTimeoutSeconds',
        'trustMode'
      ].sort()
    );
  });

  it('invoke fixture nests invocation (not flat tool/args)', () => {
    const body = cuInvokeFixture();
    expect(body.invocation).toHaveProperty('callID');
    expect(body.invocation).toHaveProperty('requestedAt');
    expect(body).not.toHaveProperty('tool');
    expect(typeof body.invocation.requestedAt).toBe('number');
  });

  it('approval.respond fixture uses approvalId/decision (Rust nests response)', () => {
    const body = cuApprovalRespondFixture();
    expect(body).toHaveProperty('approvalId');
    expect(body).toHaveProperty('decision');
    expect(body).not.toHaveProperty('reason');
  });

  it('panic_halt fixture uses source not reason', () => {
    const body = cuPanicHaltFixture();
    expect(body).toHaveProperty('source');
    expect(body).not.toHaveProperty('reason');
  });

  it('Foundation timestamp offset is 978307200', () => {
    const unix = 1_700_000_000;
    const foundation = unix - 978_307_200;
    expect(foundation).toBe(721_692_800);
  });

  it('behavioral suite uses shared session.start fixture shape', async () => {
    // Ensures goldens and invoke tests share one shape source (Issue 12).
    const fixture = cuSessionStartFixture({ trustMode: 'step' });
    expect(fixture.mode).toBe('browser');
    expect(fixture.trustMode).toBe('step');
    expect(fixture.clientID).toBe('linux-shell');
  });
});
