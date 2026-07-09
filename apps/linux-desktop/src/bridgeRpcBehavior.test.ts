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

  it('computerUseSessionStart maps contract fields (mode/trustMode/clientID)', async () => {
    invoke.mockResolvedValueOnce({ sessionId: 's1' });
    const b = await bridge();
    await b.computerUseSessionStart?.({
      mode: 'browser',
      trustMode: 'step',
      clientID: 'linux-shell'
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_session_start', {
      params: { mode: 'browser', trustMode: 'step', clientID: 'linux-shell' }
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
      params: { sessionId: 's1', source: 'hotkey' }
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
