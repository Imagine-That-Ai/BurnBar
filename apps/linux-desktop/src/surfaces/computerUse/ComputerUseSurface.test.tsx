// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { ComputerUseSurface } from './ComputerUseSurface.js';

afterEach(() => {
  cleanup();
  useShellStore.setState({ bridge: null, fixtureMode: true });
});

describe('ComputerUseSurface', () => {
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

  it('calls bridge panic halt with session id', async () => {
    const computerUsePanicHalt = vi.fn(async () => ({ ok: true }));
    const computerUseSessionStart = vi.fn(async () => ({ sessionId: 'sess-1' }));
    useShellStore.setState({
      fixtureMode: false,
      bridge: {
        computerUseSessionStart,
        computerUsePanicHalt,
        computerUseApprovalPending: vi.fn(async () => ({ requests: [] }))
      } as never
    });
    render(<ComputerUseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }));
    await waitFor(() => expect(computerUseSessionStart).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: /Panic halt/i }));
    await waitFor(() => {
      expect(computerUsePanicHalt).toHaveBeenCalledWith({ sessionId: 'sess-1', source: 'hotkey' });
    });
  });
});
