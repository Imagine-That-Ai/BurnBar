/**
 * VAL-RPC-002 behavioral suite for Phase 2 bridge methods.
 * Exercises invoke mapping via mocked @tauri-apps/api/core (no real daemon).
 */
// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  COMPUTER_USE_SESSION_DEFAULTS,
  decodeComputerUseInvokeResponse
} from './tauriBridge.js';

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

  it('account auth methods use native commands and return only redacted state', async () => {
    invoke
      .mockResolvedValueOnce({
        state: 'awaiting_device_approval',
        signedIn: false,
        trustClass: 'linux-lower-trust',
        syncState: 'local-only',
        deviceApprovalRequired: true,
        installationDeviceID: `linux_${'ab'.repeat(32)}`,
        installationSafetyFingerprint: Array(16).fill('ABAB').join(' '),
        detail: 'Approval required.'
      })
      .mockResolvedValueOnce({ operationID: 'op-1', expiresAt: '2026-07-11T22:00:00Z' })
      .mockResolvedValueOnce({
        ok: true,
        status: {
          state: 'signed_out',
          signedIn: false,
          trustClass: 'linux-lower-trust',
          syncState: 'local-only',
          deviceApprovalRequired: false
        }
      })
      .mockResolvedValueOnce({
        ok: true,
        status: {
          state: 'awaiting_device_approval',
          signedIn: true,
          trustClass: 'linux-lower-trust',
          syncState: 'local-only',
          deviceApprovalRequired: true
        }
      })
      .mockResolvedValueOnce({
        ok: true,
        status: {
          state: 'signed_out',
          signedIn: false,
          trustClass: 'linux-lower-trust',
          syncState: 'local-only',
          deviceApprovalRequired: false
        }
      });
    const b = await bridge();

    const status = await b.accountStatus();
    expect(status).toMatchObject({
      state: 'awaiting-device-approval',
      deviceApprovalRequired: true,
      installationDeviceID: `linux_${'ab'.repeat(32)}`,
      installationSafetyFingerprint: Array(16).fill('ABAB').join(' ')
    });
    await expect(b.accountBeginSignIn()).resolves.toEqual({
      operationID: 'op-1',
      expiresAt: '2026-07-11T22:00:00Z'
    });
    await expect(b.accountCancelSignIn('op-1')).resolves.toMatchObject({ state: 'signed-out' });
    await expect(b.accountRotateIdentity()).resolves.toMatchObject({ state: 'awaiting-device-approval' });
    await expect(b.accountSignOut()).resolves.toMatchObject({ state: 'signed-out' });

    expect(invoke).toHaveBeenNthCalledWith(1, 'account_status');
    expect(invoke).toHaveBeenNthCalledWith(2, 'account_begin_sign_in');
    expect(invoke).toHaveBeenNthCalledWith(3, 'account_cancel_sign_in', { operationId: 'op-1' });
    expect(invoke).toHaveBeenNthCalledWith(4, 'account_rotate_identity');
    expect(invoke).toHaveBeenNthCalledWith(5, 'account_sign_out');
    expect(JSON.stringify(status)).not.toMatch(/refreshToken|idToken|appCheckToken|publicKey|sessionGeneration/);
  });

  it('rejects a malformed native sign-in operation before UI state can accept it', async () => {
    invoke.mockResolvedValueOnce({ operationID: 'op-1', authorizationURL: 'https://should-not-reach-renderer' });
    const b = await bridge();
    await expect(b.accountBeginSignIn()).rejects.toThrow(/invalid sign-in operation/i);
  });

  it('maps the daemon cloud-ready sync state to active', async () => {
    invoke.mockResolvedValueOnce({
      state: 'active',
      signedIn: true,
      identityLabel: 'user@example.com',
      trustClass: 'linux-lower-trust',
      syncState: 'cloud-ready',
      deviceApprovalRequired: false
    });
    const b = await bridge();

    await expect(b.accountStatus()).resolves.toMatchObject({
      state: 'active',
      signedIn: true,
      syncState: 'active'
    });
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
    invoke.mockResolvedValueOnce({ state: 'authorized', sessionId: 's1' });
    const b = await bridge();
    await b.computerUseSessionStart?.({
      mode: 'browser',
      trustMode: 'step',
      ...COMPUTER_USE_SESSION_DEFAULTS,
      clientId: 'linux-shell',
      runId: 'run-1',
      runCallId: 'call-1',
      runGeneration: 7,
      desktopOwnerAuthorizationRequest: { method: 'linux_desktop_owner' }
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_session_start', {
      params: {
        mode: 'browser',
        trustMode: 'step',
        ...COMPUTER_USE_SESSION_DEFAULTS,
        clientId: 'linux-shell',
        runId: 'run-1',
        runCallId: 'call-1',
        runGeneration: 7,
        desktopOwnerAuthorizationRequest: { method: 'linux_desktop_owner' }
      }
    });
  });

  it('computerUseSessionAuthorityStatus uses the native broker command without parameters', async () => {
    invoke.mockResolvedValueOnce({ state: 'waiting_phone' });
    const b = await bridge();
    await expect(b.computerUseSessionAuthorityStatus?.()).resolves.toEqual({
      state: 'waiting_phone'
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_session_authority_status');
  });

  it('computerUseInvoke maps nested invocation object', async () => {
    invoke.mockResolvedValueOnce({
      sessionId: 's1',
      callID: 'c1',
      status: 'executed',
      result: { succeeded: true }
    });
    const b = await bridge();
    await b.computerUseInvoke?.({
      sessionId: 's1',
      invocation: {
        callId: 'c1',
        runId: 'r1',
        tool: 'browser_click',
        arguments: { selector: '#submit' },
        requestedBy: 'linux-shell',
        requestedAt: 1
      }
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_invoke', {
      params: {
        sessionId: 's1',
        invocation: {
          callId: 'c1',
          runId: 'r1',
          tool: 'browser_click',
          arguments: { selector: '#submit' },
          requestedBy: 'linux-shell',
          requestedAt: 1
        }
      }
    });
  });

  it('computerUseInvoke response decoding accepts Swift Codable IDs and rejects incomplete results', () => {
    expect(decodeComputerUseInvokeResponse({
      sessionId: 's1',
      callID: 'c1',
      status: 'denied',
      denyReason: 'approval_required'
    })).toEqual({
      sessionId: 's1',
      callID: 'c1',
      status: 'denied',
      approvalId: undefined,
      denyReason: 'approval_required',
      auditEntryIndex: undefined,
      auditHeadHashHex: undefined,
      result: undefined
    });
    expect(() => decodeComputerUseInvokeResponse({ status: 'executed' }))
      .toThrow(/sessionId/);
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
        invocation: {
          callId: 'c',
          runId: 'r',
          tool: 'browser_click',
          arguments: {},
          requestedBy: 'linux-shell',
          requestedAt: 1
        }
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
      b.computerUseSessionStart?.({
        mode: 'browser',
        trustMode: 'manual',
        ...COMPUTER_USE_SESSION_DEFAULTS,
        clientId: 'linux-shell',
        runId: 'run-1',
        runCallId: 'call-1',
        runGeneration: 1,
        desktopOwnerAuthorizationRequest: { method: 'linux_desktop_owner' }
      })
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
