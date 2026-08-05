// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import type { LinuxShellBridge, SmartHubCommandResult, SmartHubOperation } from '../../tauriBridge.js';
import { SmartHubSurface } from './SmartHubSurface.js';

function resetShell(): void {
  cleanup();
  useShellStore.setState({
    bridge: null,
    bridgeReady: true,
    fixtureMode: false,
    health: null,
    healthError: null,
    healthBusy: false,
    route: 'smarthub'
  });
}

function statusResult(operation: SmartHubOperation = 'status'): SmartHubCommandResult {
  if (operation === 'parity') return { operation, payload: { integrations: [] } };
  if (operation === 'discover') {
    return {
      operation,
      payload: [{ adapter: 'smart_hub_bridge', serviceType: '_openburnbar-peer._tcp', instances: [], rawTranscript: '' }]
    };
  }
  return {
    operation,
    payload: {
      adapter: operation === 'cast_status' ? 'google_cast' : operation === 'homeassistant_status' ? 'home_assistant' : 'smart_hub_bridge',
      status: 'blocked_bridge_not_reachable',
      blocker: 'Start the bridge before retrying.',
      details: { status: 'blocked_bridge_not_reachable', blocker: 'Start the bridge before retrying.' }
    }
  };
}

function bridgeWithCommand(command: (operation: SmartHubOperation) => Promise<SmartHubCommandResult>): LinuxShellBridge {
  return { smartHubCommand: command, integrationsStatus: vi.fn() } as unknown as LinuxShellBridge;
}

describe('P28 SmartHub surface', () => {
  beforeEach(resetShell);
  afterEach(cleanup);

  it('renders fixture output with an explicit non-live source label', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<SmartHubSurface />);
    await waitFor(() => expect(screen.getByText(/fixture transcript \(not live device proof\)/)).toBeTruthy());
    expect(screen.getAllByText('fixture_capability').length).toBeGreaterThan(0);
  });

  it('uses the typed status operation instead of the removed runCli escape hatch', async () => {
    const command = vi.fn(async (operation: SmartHubOperation) => statusResult(operation));
    useShellStore.setState({ bridge: bridgeWithCommand(command) });
    render(<SmartHubSurface />);
    await waitFor(() => expect(command).toHaveBeenCalledWith('status', expect.objectContaining({ requestId: expect.stringMatching(/^smarthub-/) })));
    expect(screen.getAllByText('blocked_bridge_not_reachable').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Start the bridge before retrying.').length).toBeGreaterThan(0);
  });

  it('passes only an allowlisted operation when the selection changes', async () => {
    const command = vi.fn(async (operation: SmartHubOperation) => statusResult(operation));
    useShellStore.setState({ bridge: bridgeWithCommand(command) });
    render(<SmartHubSurface />);
    await waitFor(() => expect(command).toHaveBeenCalledWith('status', expect.objectContaining({ requestId: expect.stringMatching(/^smarthub-/) })));
    command.mockClear();
    fireEvent.change(screen.getByLabelText('Operation'), { target: { value: 'discover' } });
    await waitFor(() => expect(command).toHaveBeenCalledWith('discover', expect.objectContaining({ requestId: expect.stringMatching(/^smarthub-/) })));
    expect(screen.getByText('Discovery')).toBeTruthy();
  });

  it('exposes the typed PixelClock control probe already supported by the native contract', async () => {
    const command = vi.fn(async (operation: SmartHubOperation) => statusResult(operation));
    useShellStore.setState({ bridge: bridgeWithCommand(command) });
    render(<SmartHubSurface />);
    await waitFor(() => expect(command).toHaveBeenCalledWith('status', expect.anything()));
    command.mockClear();

    fireEvent.change(screen.getByLabelText('Operation'), { target: { value: 'pixel_clock_control' } });
    await waitFor(() => expect(command).toHaveBeenCalledWith(
      'pixel_clock_control',
      expect.objectContaining({ requestId: expect.stringMatching(/^smarthub-/) })
    ));
    expect(screen.getByText('PixelClock control probe')).toBeTruthy();
  });

  it('clears the previous device result while a replacement operation is pending', async () => {
    let resolveDiscover: ((result: SmartHubCommandResult) => void) | undefined;
    const command = vi.fn()
      .mockResolvedValueOnce(statusResult('status'))
      .mockImplementationOnce(() => new Promise<SmartHubCommandResult>((resolve) => {
        resolveDiscover = resolve;
      }));
    useShellStore.setState({ bridge: bridgeWithCommand(command) });
    render(<SmartHubSurface />);
    await waitFor(() => expect(screen.getAllByText('blocked_bridge_not_reachable').length).toBeGreaterThan(0));

    fireEvent.change(screen.getByLabelText('Operation'), { target: { value: 'discover' } });
    await waitFor(() => expect(command).toHaveBeenCalledWith('discover', expect.anything()));
    expect(screen.queryByText('blocked_bridge_not_reachable')).toBeNull();
    expect(screen.getByRole('status').textContent).toMatch(/Checking Linux device capability/i);

    resolveDiscover?.(statusResult('discover'));
    await waitFor(() => expect(screen.getByText('Discovery')).toBeTruthy());
  });

  it('renders a bounded Avahi timeout as an actionable discovery outcome', async () => {
    const command = vi.fn(async (operation: SmartHubOperation): Promise<SmartHubCommandResult> => {
      if (operation === 'discover') {
        return {
          operation,
          payload: [{
            adapter: 'smart_hub_bridge',
            serviceType: '_openburnbar-peer._tcp',
            instances: [],
            rawTranscript: '<avahi-timeout>',
            status: 'timeout',
            blocker: 'Avahi discovery exceeded the timeout.'
          }]
        };
      }
      return statusResult(operation);
    });
    useShellStore.setState({ bridge: bridgeWithCommand(command) });
    render(<SmartHubSurface />);
    await waitFor(() => expect(command).toHaveBeenCalledWith('status', expect.anything()));
    fireEvent.change(screen.getByLabelText('Operation'), { target: { value: 'discover' } });
    await waitFor(() => expect(screen.getByText('timeout')).toBeTruthy());
    expect(screen.getByText('Avahi discovery exceeded the timeout.')).toBeTruthy();
  });

  it('uses the existing integrations status method for older shells on parity only', async () => {
    const integrationsStatus = vi.fn(async () => ({ integrations: [] }));
    useShellStore.setState({ bridge: { integrationsStatus } as unknown as LinuxShellBridge });
    render(<SmartHubSurface />);
    fireEvent.change(screen.getByLabelText('Operation'), { target: { value: 'parity' } });
    await waitFor(() => expect(integrationsStatus).toHaveBeenCalled());
    expect(await screen.findByRole('heading', { name: 'Integration status' })).toBeTruthy();
  });

  it('reports the packaged capability boundary without attempting generic shell execution', async () => {
    render(<SmartHubSurface />);
    await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(/Packaged shell/));
    expect(screen.queryByText(/runCli/)).toBeNull();
  });

  it('allows a manual retry after a command failure', async () => {
    const command = vi
      .fn<(_: SmartHubOperation) => Promise<SmartHubCommandResult>>()
      .mockRejectedValueOnce(new Error('openburnbar_cli_smarthub_command_failed'))
      .mockResolvedValue(statusResult());
    useShellStore.setState({ bridge: bridgeWithCommand(command) });
    render(<SmartHubSurface />);
    await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(/command_failed/));
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Run operation' }));
    });
    await waitFor(() => expect(screen.getAllByText('blocked_bridge_not_reachable').length).toBeGreaterThan(0));
  });

  it('cancels an in-flight packaged operation and does not render its late result', async () => {
    let resolveCommand: ((result: SmartHubCommandResult) => void) | undefined;
    const command = vi.fn(() => new Promise<SmartHubCommandResult>((resolve) => {
      resolveCommand = resolve;
    }));
    const cancel = vi.fn(async () => undefined);
    useShellStore.setState({ bridge: { ...bridgeWithCommand(command), smartHubCancel: cancel } });
    render(<SmartHubSurface />);
    await waitFor(() => expect(command).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(cancel).toHaveBeenCalledWith(expect.stringMatching(/^smarthub-/));
    expect(screen.getByRole('alert').textContent).toMatch(/cancelled/i);
    resolveCommand?.(statusResult());
    await waitFor(() => expect(screen.queryByText('blocked_bridge_not_reachable')).toBeNull());
  });

  it('cancels an in-flight operation when the shell becomes unavailable', async () => {
    let resolveCommand: ((result: SmartHubCommandResult) => void) | undefined;
    const command = vi.fn(() => new Promise<SmartHubCommandResult>((resolve) => {
      resolveCommand = resolve;
    }));
    const cancel = vi.fn(async () => undefined);
    useShellStore.setState({ bridge: { ...bridgeWithCommand(command), smartHubCancel: cancel } });
    render(<SmartHubSurface />);
    await waitFor(() => expect(command).toHaveBeenCalled());

    act(() => useShellStore.setState({ bridgeReady: false }));
    await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(/shell is unavailable/i));
    expect(cancel).toHaveBeenCalledWith(expect.stringMatching(/^smarthub-/));
    resolveCommand?.(statusResult());
    await waitFor(() => expect(screen.queryByText('blocked_bridge_not_reachable')).toBeNull());
  });
});
