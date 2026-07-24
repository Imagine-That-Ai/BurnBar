// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { makeAvailableRuntimeCapabilityManifest } from '../../testing/bridgeStubs.js';
import {
  COMPUTER_USE_SESSION_DEFAULTS,
  type ComputerUseSessionAuthorityStatus,
  type ComputerUseSessionStartRequest
} from '../../tauriBridge.js';
import {
  buildComputerUseBrowserInvokeParams,
  buildComputerUseSessionStartParams,
  clearSessionIfCurrent,
  ComputerUseSurface,
  isAuthoritativeInvalidSessionError
} from './ComputerUseSurface.js';

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((nextResolve) => {
    resolve = nextResolve;
  });
  return { promise, resolve };
}

afterEach(() => {
  cleanup();
  useShellStore.setState({ bridge: null, fixtureMode: true, runtimeCapabilities: null });
});

describe('ComputerUseSurface', () => {
  it('ignores a stale approval poll after a newer response wins', async () => {
    const firstPoll = deferred<unknown>();
    const computerUseApprovalPending = vi.fn()
      .mockImplementationOnce(() => firstPoll.promise)
      .mockResolvedValueOnce({
        requests: [{
          approvalId: 'new-approval',
          title: 'New approval'
        }],
        runRequirements: [{
          runID: 'new-run',
          callID: 'new-call',
          generation: 2,
          toolKind: 'browser_goto'
        }]
      })
      .mockResolvedValue({ requests: [] });
    useShellStore.setState({
      fixtureMode: false,
      runtimeCapabilities: makeAvailableRuntimeCapabilityManifest(),
      bridge: {
        computerUseSessionAuthorityStatus: vi.fn(async () => ({ state: 'available' as const })),
        computerUseApprovalPending
      } as never
    });

    render(<ComputerUseSurface />);
    fireEvent.click(await screen.findByRole('button', { name: /Refresh approvals/i }));
    await waitFor(() => expect(computerUseApprovalPending).toHaveBeenCalledTimes(2));
    expect(await screen.findByText('New approval')).toBeTruthy();

    await act(async () => {
      firstPoll.resolve({
        requests: [{ approvalId: 'old-approval', title: 'Old approval' }],
        runRequirements: [{
          runID: 'old-run',
          callID: 'old-call',
          generation: 1,
          toolKind: 'browser_goto'
        }]
      });
      await firstPoll.promise;
    });

    expect(screen.getByText('New approval')).toBeTruthy();
    expect(screen.queryByText('Old approval')).toBeNull();
    expect(screen.getByRole('option', { name: /new-run/i })).toBeTruthy();
    expect(screen.queryByRole('option', { name: /old-run/i })).toBeNull();
  });

  it('ignores an authority response from a replaced bridge', async () => {
    const firstProbe = deferred<ComputerUseSessionAuthorityStatus>();
    const oldBridge = {
      computerUseSessionAuthorityStatus: vi.fn(() => firstProbe.promise),
      computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
    };
    const newBridge = {
      computerUseSessionAuthorityStatus: vi.fn(async () => ({
        state: 'authorized' as const,
        sessionId: 'new-session'
      })),
      computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
    };
    useShellStore.setState({
      fixtureMode: false,
      runtimeCapabilities: makeAvailableRuntimeCapabilityManifest(),
      bridge: oldBridge as never
    });

    render(<ComputerUseSurface />);
    act(() => useShellStore.setState({ bridge: newBridge as never }));
    expect(await screen.findByText(/Computer Use authorization complete/i)).toBeTruthy();
    expect(screen.getByText(/Session · new-sess/i)).toBeTruthy();

    await act(async () => {
      firstProbe.resolve({ state: 'waiting_phone' });
      await firstProbe.promise;
    });

    expect(screen.getByText(/Computer Use authorization complete/i)).toBeTruthy();
    expect(screen.getByText(/Session · new-sess/i)).toBeTruthy();
    expect(screen.queryByText(/Waiting for approval on your paired phone/i)).toBeNull();
  });

  it('builds an exact session start payload from the selected run requirement', () => {
    expect(buildComputerUseSessionStartParams(' run-1 ', 'step', [
      { runID: 'run-other', callID: 'call-other', generation: 99 },
      { runID: 'run-1', callID: 'call-1', generation: 7 }
    ])).toEqual({
      mode: 'browser',
      trustMode: 'step',
      ...COMPUTER_USE_SESSION_DEFAULTS,
      clientId: 'linux-shell',
      runId: 'run-1',
      runCallId: 'call-1',
      runGeneration: 7,
      desktopOwnerAuthorizationRequest: {
        method: 'linux_desktop_owner'
      }
    });
  });

  it.each([
    ['available', 'Ready to request paired-phone Computer Use authorization.'],
    ['waiting_phone', 'Waiting for approval on your paired phone.'],
    ['waiting_local_owner', 'Waiting for Linux desktop-owner authorization.'],
    ['expired', 'authorization request expired'],
    ['rejected', 'authorization request was rejected'],
    ['unavailable', 'Paired phone approval is unavailable']
  ] as const)('exposes the %s broker state without authority material', async (state, copy) => {
    useShellStore.setState({
      fixtureMode: false,
      bridge: {
        computerUseSessionAuthorityStatus: vi.fn(async () => ({ state })),
        computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
      } as never
    });

    render(<ComputerUseSurface />);
    await waitFor(() => {
      expect(screen.getByRole('status').textContent).toMatch(new RegExp(copy, 'i'));
    });
  });

  it('exposes authorized only with the native broker session', async () => {
    useShellStore.setState({
      fixtureMode: false,
      bridge: {
        computerUseSessionAuthorityStatus: vi.fn(async () => ({
          state: 'authorized',
          sessionId: 'native-session-1'
        })),
        computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
      } as never
    });

    render(<ComputerUseSurface />);
    expect(await screen.findByText(/Computer Use authorization complete/i)).toBeTruthy();
    expect(screen.getByText(/Session · native-sess/i)).toBeTruthy();
  });

  it('sends only the typed run and Linux owner-authorization request to the native broker', async () => {
    const computerUseSessionStart = vi.fn(
      async (_request: ComputerUseSessionStartRequest) => ({ state: 'waiting_phone' as const })
    );
    useShellStore.setState({
      fixtureMode: false,
      runtimeCapabilities: makeAvailableRuntimeCapabilityManifest(),
      bridge: {
        computerUseSessionAuthorityStatus: vi.fn(async () => ({ state: 'available' as const })),
        computerUseSessionStart,
        computerUseApprovalPending: vi.fn(async () => ({
          requests: [],
          runRequirements: [{
            runID: 'run-safe',
            callID: 'call-safe',
            generation: 11,
            toolKind: 'browser_goto'
          }]
        }))
      } as never
    });

    render(<ComputerUseSurface />);
    const runPicker = await screen.findByRole('combobox', { name: /Agent run/i });
    fireEvent.change(runPicker, { target: { value: 'run-safe' } });
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));

    await waitFor(() => expect(computerUseSessionStart).toHaveBeenCalledOnce());
    const request = computerUseSessionStart.mock.calls[0]?.[0];
    expect(request).toEqual({
      mode: 'browser',
      trustMode: 'step',
      ...COMPUTER_USE_SESSION_DEFAULTS,
      clientId: 'linux-shell',
      runId: 'run-safe',
      runCallId: 'call-safe',
      runGeneration: 11,
      desktopOwnerAuthorizationRequest: { method: 'linux_desktop_owner' }
    });
    expect(JSON.stringify(request)).not.toMatch(
      /private|password|signature|proof|localAuthenticationSatisfied|authorized\s*:/i
    );
    expect(await screen.findByText(/Waiting for approval on your paired phone/i)).toBeTruthy();
  });

  it('builds the lower-camel Tauri invoke shape and preserves the Swift wire IDs for Rust', () => {
    expect(buildComputerUseBrowserInvokeParams(
      'session-1',
      'run-1',
      { tool: 'browser_fill', url: '', selector: '#email', text: 'alberto@example.com' },
      [{ runID: 'run-1', callID: 'call-1', generation: 9, toolKind: 'browser_fill' }],
      123.5
    )).toEqual({
      sessionId: 'session-1',
      invocation: {
        callId: 'call-1',
        runId: 'run-1',
        tool: 'browser_fill',
        arguments: { selector: '#email', text: 'alberto@example.com' },
        requestedBy: 'linux-shell',
        requestedAt: 123.5
      }
    });
  });

  it('invokes an explicit browser action and renders an approval-gated result', async () => {
    const computerUseInvoke = vi.fn(async () => ({
      sessionId: 'native-session-1',
      callID: 'call-1',
      status: 'awaiting_approval' as const,
      approvalId: 'approval-1'
    }));
    useShellStore.setState({
      fixtureMode: false,
      runtimeCapabilities: makeAvailableRuntimeCapabilityManifest(),
      bridge: {
        computerUseSessionAuthorityStatus: vi.fn(async () => ({
          state: 'authorized' as const,
          sessionId: 'native-session-1'
        })),
        computerUseApprovalPending: vi.fn(async () => ({
          requests: [],
          runRequirements: [{ runID: 'run-1', callID: 'call-1', generation: 3, toolKind: 'browser_goto' }]
        })),
        computerUseInvoke
      } as never
    });

    render(<ComputerUseSurface />);
    await screen.findByText(/Session · native-sess/i);
    fireEvent.change(screen.getByRole('combobox', { name: /Agent run/i }), { target: { value: 'run-1' } });
    fireEvent.change(screen.getByRole('textbox', { name: /Browser URL/i }), {
      target: { value: 'https://example.test' }
    });
    fireEvent.click(screen.getByRole('button', { name: /Send for approval/i }));

    await waitFor(() => expect(computerUseInvoke).toHaveBeenCalledOnce());
    expect(computerUseInvoke).toHaveBeenCalledWith({
      sessionId: 'native-session-1',
      invocation: {
        callId: 'call-1',
        runId: 'run-1',
        tool: 'browser_goto',
        arguments: { url: 'https://example.test' },
        requestedBy: 'linux-shell',
        requestedAt: expect.any(Number)
      }
    });
    expect(await screen.findByText(/Action status: awaiting_approval/i)).toBeTruthy();
    expect(screen.getByText(/Approval · approval-1/i)).toBeTruthy();
  });

  it('retires the exact session when a browser action reports an authoritative session error', async () => {
    const computerUseInvoke = vi.fn(async () => {
      throw new Error('Computer Use session is not active: native-session-1.');
    });
    useShellStore.setState({
      fixtureMode: false,
      runtimeCapabilities: makeAvailableRuntimeCapabilityManifest(),
      bridge: {
        computerUseSessionAuthorityStatus: vi.fn(async () => ({
          state: 'authorized' as const,
          sessionId: 'native-session-1'
        })),
        computerUseApprovalPending: vi.fn(async () => ({
          requests: [],
          runRequirements: [{ runID: 'run-1', callID: 'call-1', generation: 3, toolKind: 'browser_screenshot' }]
        })),
        computerUseInvoke
      } as never
    });

    render(<ComputerUseSurface />);
    await screen.findByText(/Session · native-sess/i);
    fireEvent.change(screen.getByRole('combobox', { name: /Agent run/i }), { target: { value: 'run-1' } });
    fireEvent.change(screen.getByRole('combobox', { name: /Browser action/i }), {
      target: { value: 'browser_screenshot' }
    });
    fireEvent.click(screen.getByRole('button', { name: /Send for approval/i }));

    await waitFor(() => expect(screen.queryByText(/Session · native-sess/i)).toBeNull());
    expect(screen.getByRole('alert').textContent).toMatch(/session is not active/i);
  });

  it('keeps system mode hidden when the native capability probe is unavailable', async () => {
    const manifest = makeAvailableRuntimeCapabilityManifest();
    manifest.capabilities = manifest.capabilities.map((entry) => entry.id === 'computer-use.system'
      ? { ...entry, state: 'unavailable', reason: 'PipeWire capture is not available.' }
      : entry);
    useShellStore.setState({
      fixtureMode: false,
      runtimeCapabilities: manifest,
      bridge: {
        computerUseSessionAuthorityStatus: vi.fn(async () => ({ state: 'unavailable' as const })),
        computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
      } as never
    });

    render(<ComputerUseSurface />);
    expect(await screen.findByText(/System Computer Use is unavailable/i)).toBeTruthy();
    expect(screen.queryByRole('option', { name: /System/i })).toBeNull();
    expect((screen.getByRole('button', { name: /Start session/i }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('fails closed when the native capability probe rejects', async () => {
    const computerUseSessionStart = vi.fn(async () => ({ sessionId: 'should-not-start' }));
    useShellStore.setState({
      fixtureMode: false,
      runtimeCapabilities: null,
      bridge: {
        runtimeCapabilities: vi.fn(async () => {
          throw new Error('daemon capability probe failed');
        }),
        computerUseSessionAuthorityStatus: vi.fn(async () => ({ state: 'available' as const })),
        computerUseSessionStart,
        computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
      } as never
    });

    render(<ComputerUseSurface />);
    expect(await screen.findByText(/Browser Computer Use is unavailable until/i)).toBeTruthy();
    const start = screen.getByRole('button', { name: /Start session/i }) as HTMLButtonElement;
    expect(start.disabled).toBe(true);
    fireEvent.click(start);
    expect(computerUseSessionStart).not.toHaveBeenCalled();
    expect(screen.getByText(/daemon capability probe failed/i)).toBeTruthy();
  });

  it('fails closed when a native bridge has no capability probe', async () => {
    const computerUseSessionStart = vi.fn(async () => ({ sessionId: 'should-not-start' }));
    useShellStore.setState({
      fixtureMode: false,
      runtimeCapabilities: null,
      bridge: {
        computerUseSessionAuthorityStatus: vi.fn(async () => ({ state: 'available' as const })),
        computerUseSessionStart,
        computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
      } as never
    });

    render(<ComputerUseSurface />);
    expect(await screen.findByText(/Browser Computer Use is unavailable until/i)).toBeTruthy();
    expect(screen.getByText(/runtime capability probe is unavailable/i)).toBeTruthy();
    expect((screen.getByRole('button', { name: /Start session/i }) as HTMLButtonElement).disabled).toBe(true);
    expect(computerUseSessionStart).not.toHaveBeenCalled();
  });

  it('uses a fixture approval result without dispatching a native action', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null, runtimeCapabilities: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await screen.findByText(/Session · fixture-ses/i);
    fireEvent.click(screen.getByRole('button', { name: /Send for approval/i }));
    expect(await screen.findByText(/Action status: awaiting_approval/i)).toBeTruthy();
    expect(screen.getByText(/Approval · fixture-approval/i)).toBeTruthy();
  });

  it('starts a fixture session and shows pending approvals', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await waitFor(() => {
      expect(screen.getByText(/Session · fixture-ses/i)).toBeTruthy();
    });
    fireEvent.click(screen.getByRole('button', { name: /Refresh approvals/i }));
    await waitFor(() => {
      expect(screen.getByText(/fixture-approval/)).toBeTruthy();
    });
  });

  it('calls the real bridge panic halt for the exact selected session', async () => {
    const computerUsePanicHalt = vi.fn(async () => ({
      sessionId: 'fixture-session',
      endedAt: new Date(0).toISOString(),
      auditHeadHashHex: '',
      source: 'hotkey' as const
    }));
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await screen.findByText(/Session · fixture-ses/i);

    act(() => {
      useShellStore.setState({
        fixtureMode: false,
        bridge: {
          computerUsePanicHalt,
          computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
        } as never
      });
    });
    fireEvent.click(screen.getByRole('button', { name: /Panic halt/i }));

    await waitFor(() => {
      expect(computerUsePanicHalt).toHaveBeenCalledWith({
        sessionId: 'fixture-session',
        source: 'hotkey'
      });
      expect(screen.queryByText(/Session · fixture-ses/i)).toBeNull();
    });
  });

  it('keeps a selected session when panic succeeds without a terminal response', async () => {
    const computerUsePanicHalt = vi.fn(async () => ({ ok: true }));
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await screen.findByText(/Session · fixture-ses/i);

    act(() => {
      useShellStore.setState({
        fixtureMode: false,
        bridge: {
          computerUsePanicHalt,
          computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
        } as never
      });
    });
    fireEvent.click(screen.getByRole('button', { name: /Panic halt/i }));

    await waitFor(() => expect(computerUsePanicHalt).toHaveBeenCalledOnce());
    expect(screen.getByText(/Session · fixture-ses/i)).toBeTruthy();
  });

  it('clears an invalid session reported by panic halt', async () => {
    const computerUsePanicHalt = vi.fn(async () => {
      throw new Error('Computer Use session is not active: fixture-session.');
    });
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await screen.findByText(/Session · fixture-ses/i);

    act(() => {
      useShellStore.setState({
        fixtureMode: false,
        bridge: {
          computerUsePanicHalt,
          computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
        } as never
      });
    });
    fireEvent.click(screen.getByRole('button', { name: /Panic halt/i }));

    await waitFor(() => expect(screen.queryByText(/Session · fixture-ses/i)).toBeNull());
    expect(computerUsePanicHalt).toHaveBeenCalledWith({
      sessionId: 'fixture-session',
      source: 'hotkey'
    });
  });

  it('clears an invalid session reported by audit export', async () => {
    const computerUseApprovalPending = vi.fn(async () => ({ requests: [] }));
    const computerUseAuditExport = vi.fn(async () => {
      throw new Error('Computer Use session is not active: fixture-session.');
    });
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await screen.findByText(/Session · fixture-ses/i);

    act(() => {
      useShellStore.setState({
        fixtureMode: false,
        bridge: {
          computerUseApprovalPending,
          computerUseAuditExport
        } as never
      });
    });
    fireEvent.click(screen.getByRole('button', { name: /Export audit/i }));

    await waitFor(() => expect(screen.queryByText(/Session · fixture-ses/i)).toBeNull());
    expect(computerUseAuditExport).toHaveBeenCalledWith({
      sessionId: 'fixture-session',
      includeScreenshots: true,
      anchorOpenTimestamps: false
    });
    expect(computerUseApprovalPending).toHaveBeenCalledWith({ sessionId: 'fixture-session' });
  });

  it('clears an unknown session reported by pending refresh', async () => {
    const computerUseApprovalPending = vi.fn(async () => {
      throw new Error('Unknown Computer Use session: fixture-session.');
    });
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await screen.findByText(/Session · fixture-ses/i);

    act(() => {
      useShellStore.setState({
        fixtureMode: false,
        bridge: {
          computerUseApprovalPending
        } as never
      });
    });

    await waitFor(() => expect(screen.queryByText(/Session · fixture-ses/i)).toBeNull());
    expect(computerUseApprovalPending).toHaveBeenCalledWith({ sessionId: 'fixture-session' });
  });

  it('retires the exact session when filtered polling reports it inactive', async () => {
    const computerUseApprovalPending = vi.fn(async () => ({
      requests: [],
      sessionActive: false
    }));
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await screen.findByText(/Session · fixture-ses/i);

    act(() => {
      useShellStore.setState({
        fixtureMode: false,
        bridge: { computerUseApprovalPending } as never
      });
    });

    await waitFor(() => expect(screen.queryByText(/Session · fixture-ses/i)).toBeNull());
    expect(computerUseApprovalPending).toHaveBeenCalledWith({ sessionId: 'fixture-session' });
  });

  it('retains the selected session when filtered polling has a transport failure', async () => {
    const computerUseApprovalPending = vi.fn(async () => {
      throw new Error('daemon down');
    });
    useShellStore.setState({ fixtureMode: true, bridge: null });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await screen.findByText(/Session · fixture-ses/i);

    act(() => {
      useShellStore.setState({
        fixtureMode: false,
        bridge: { computerUseApprovalPending } as never
      });
    });

    await waitFor(() => expect(computerUseApprovalPending).toHaveBeenCalledWith({
      sessionId: 'fixture-session'
    }));
    expect(screen.getByText(/Session · fixture-ses/i)).toBeTruthy();
  });

  it('does not ABA-clear a replacement session', () => {
    expect(clearSessionIfCurrent('replacement-session', 'stale-session')).toBe('replacement-session');
    expect(clearSessionIfCurrent('stale-session', 'stale-session')).toBeNull();
  });

  it('distinguishes authoritative invalid-session errors from transport failures', () => {
    expect(isAuthoritativeInvalidSessionError(
      new Error('Computer Use session is not active: session-1.')
    )).toBe(true);
    expect(isAuthoritativeInvalidSessionError(new Error('daemon down'))).toBe(false);
  });

  it('lists waiting runs but keeps release session controls disabled without signed authority', async () => {
    const computerUsePanicHalt = vi.fn(async () => ({ ok: true }));
    const computerUseSessionStart = vi.fn(async () => ({ sessionId: 'sess-1' }));
    useShellStore.setState({
      fixtureMode: false,
      bridge: {
        computerUseSessionStart,
        computerUsePanicHalt,
        computerUseApprovalPending: vi.fn(async () => ({
          requests: [],
          runRequirements: [{ runID: 'run-1', callID: 'call-1', toolKind: 'browser_goto', generation: 1 }]
        }))
      } as never
    });
    render(<ComputerUseSurface />);
    const runPicker = await screen.findByRole('combobox', { name: /Agent run/i });
    fireEvent.change(runPicker, {
      target: { value: 'run-1' }
    });
    expect(screen.getByText(/Paired phone approval is unavailable/i)).toBeTruthy();
    expect((screen.getByRole('button', { name: /Start session/i }) as HTMLButtonElement).disabled).toBe(true);
    expect(computerUseSessionStart).not.toHaveBeenCalled();
    expect(computerUsePanicHalt).not.toHaveBeenCalled();
  });

  it('fails closed before dispatch when signed phone authority is unavailable', async () => {
    const computerUseSessionStart = vi.fn(async () => ({ sessionId: 'should-not-start' }));
    useShellStore.setState({
      fixtureMode: false,
      bridge: {
        computerUseSessionStart,
        computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
      } as never
    });

    render(<ComputerUseSurface />);
    expect((await screen.findByRole('status')).textContent).toMatch(/Paired phone approval is unavailable/i);
    expect((screen.getByRole('button', { name: /Start session/i }) as HTMLButtonElement).disabled).toBe(true);
    expect(computerUseSessionStart).not.toHaveBeenCalled();
  });

  it('renders the action context instead of only an opaque approval id', async () => {
    const computerUseApprovalRespond = vi.fn(async () => ({ accepted: true }));
    useShellStore.setState({
      fixtureMode: false,
      bridge: {
        computerUseApprovalPending: vi.fn(async () => ({
          requests: [{
            approvalId: 'approval-1',
            title: 'Submit the visible form',
            message: 'Send the form after reviewing its contents.',
            toolKind: 'browser_click',
            trustMode: 'manual',
            runId: 'run-context',
            sessionId: 'session-context',
            beforeScreenshotPNGBase64: 'aGVsbG8=',
            beforeScreenshotMimeType: 'image/png'
          }]
        })),
        computerUseApprovalRespond
      } as never
    });

    render(<ComputerUseSurface />);

    expect(await screen.findByText('Submit the visible form')).toBeTruthy();
    expect(screen.getByText('Send the form after reviewing its contents.')).toBeTruthy();
    expect(screen.getByText(/run run-context/)).toBeTruthy();
    expect(screen.getByAltText(/Pre-action browser state/i)).toBeTruthy();
    const approve = screen.getByRole('button', { name: /Approve Submit the visible form/i }) as HTMLButtonElement;
    expect(approve.disabled).toBe(true);
    expect(computerUseApprovalRespond).not.toHaveBeenCalled();
    expect(screen.queryByRole('option', { name: /System/i })).toBeNull();
  });
});
