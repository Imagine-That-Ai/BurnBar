// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureMissionList } from '../../daemonFixture.js';
import { useShellStore } from '../../state/shellStore.js';
import { useMissionsStore } from '../../state/missionsStore.js';
import type { LinuxShellBridge, MissionListResult } from '../../tauriBridge.js';
import { MissionsSurface } from './MissionsSurface.js';

function resetStores(): void {
  useShellStore.setState({
    fixtureMode: false,
    bridge: null,
    bridgeReady: true,
    health: null,
    healthError: null
  });
  useMissionsStore.setState({
    data: null,
    loading: false,
    error: null,
    approvalById: {}
  });
}

function stubLoad(preset: () => void): void {
  vi.spyOn(useMissionsStore.getState(), 'load').mockImplementation(async () => {
    preset();
  });
}

function renderMissions() {
  return render(<MissionsSurface />);
}

describe('MissionsSurface', () => {
  beforeEach(() => {
    resetStores();
    vi.useRealTimers();
  });
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('renders populated fixture missions with grouping and controller stats', () => {
    const fx = fixtureMissionList();
    useShellStore.setState({ fixtureMode: true });
    stubLoad(() => useMissionsStore.setState({ data: fx, loading: false, error: null }));
    useMissionsStore.setState({ data: fx, loading: false, error: null });
    renderMissions();
    expect(screen.getByRole('status', { name: /mission runway metrics/i })).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'Running' })).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'Blocked' })).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'Completed' })).toBeTruthy();
    expect(screen.getByText('Port dashboard to Linux')).toBeTruthy();
    expect(screen.getByText(/fixture transcript/)).toBeTruthy();
  });

  it('shows loading state', () => {
    useShellStore.setState({ fixtureMode: true });
    stubLoad(() => useMissionsStore.setState({ loading: true, data: null, error: null }));
    useMissionsStore.setState({ loading: true, data: null, error: null });
    renderMissions();
    expect(screen.getByText(/loading missions/i).getAttribute('aria-busy')).toBe('true');
  });

  it('shows empty state when no missions or approvals', () => {
    const empty: MissionListResult = { missions: [], pendingApprovals: [] };
    useShellStore.setState({ fixtureMode: true });
    stubLoad(() => useMissionsStore.setState({ data: empty, loading: false, error: null }));
    useMissionsStore.setState({ data: empty, loading: false, error: null });
    renderMissions();
    expect(screen.getByText(/no missions — dispatch from the daemon/i)).toBeTruthy();
  });

  it('shows error state with retry', () => {
    useShellStore.setState({ fixtureMode: true });
    stubLoad(() =>
      useMissionsStore.setState({ error: 'Daemon unreachable', data: null, loading: false })
    );
    useMissionsStore.setState({ error: 'Daemon unreachable', data: null, loading: false });
    renderMissions();
    expect(screen.getByRole('alert').textContent).toContain('Daemon unreachable');
    expect(screen.getByRole('button', { name: /retry/i })).toBeTruthy();
  });

  it('shows offline notice without bridge', async () => {
    useShellStore.setState({ fixtureMode: false, bridge: null });
    stubLoad(() =>
      useMissionsStore.setState({
        data: null,
        loading: false,
        error: 'Packaged shell required for live data.'
      })
    );
    renderMissions();
    await act(async () => {
      await useMissionsStore.getState().load();
    });
    expect(screen.getByText(/Missions need the packaged shell/i)).toBeTruthy();
  });

  it('groups missions into lifecycle sections', () => {
    const fx = fixtureMissionList();
    useShellStore.setState({ fixtureMode: true });
    stubLoad(() => useMissionsStore.setState({ data: fx, loading: false, error: null }));
    useMissionsStore.setState({ data: fx, loading: false, error: null });
    renderMissions();
    const runningHeading = screen.getByRole('heading', { name: 'Running' });
    const blockedHeading = screen.getByRole('heading', { name: 'Blocked' });
    const completedHeading = screen.getByRole('heading', { name: 'Completed' });
    expect(within(runningHeading.closest('section')!).getByText('Port dashboard to Linux')).toBeTruthy();
    expect(within(blockedHeading.closest('section')!).getByText('Onboarding wizard polish')).toBeTruthy();
    expect(within(completedHeading.closest('section')!).getByText('Memory recall boundary audit')).toBeTruthy();
  });

  it('renders state filter chips with counts', () => {
    const fx = fixtureMissionList();
    useShellStore.setState({ fixtureMode: true });
    useMissionsStore.setState({ data: fx, loading: false, error: null });
    renderMissions();
    expect(screen.getByRole('group', { name: /mission state filter/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /^All\b/i }).getAttribute('aria-pressed')).toBe('true');
  });

  it('requires two-step confirm for high-risk approve', () => {
    const fx = fixtureMissionList();
    useShellStore.setState({ fixtureMode: true });
    stubLoad(() => useMissionsStore.setState({ data: fx, loading: false, error: null }));
    useMissionsStore.setState({ data: fx, loading: false, error: null });
    renderMissions();
    fireEvent.click(screen.getByRole('button', { name: /approve port dashboard to linux/i }));
    expect(screen.getByRole('button', { name: /confirm approve for port dashboard to linux/i })).toBeTruthy();
  });

  it('shows pending spinner during decision without optimistic removal', async () => {
    let resolveDecision: (() => void) | undefined;
    const decisionPromise = new Promise<void>((resolve) => {
      resolveDecision = resolve;
    });
    const initial = fixtureMissionList();
    const missionList = vi.fn().mockImplementation(() => decisionPromise.then(() => initial));
    const missionApprovalDecision = vi.fn(() => decisionPromise);
    const bridge = { missionList, missionApprovalDecision } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    stubLoad(() => useMissionsStore.setState({ data: initial, loading: false, error: null }));
    useMissionsStore.setState({ data: initial, loading: false, error: null });
    renderMissions();

    fireEvent.click(screen.getByRole('button', { name: /deny refactor provider routing/i }));

    expect(screen.getByText(/submitting decision/i)).toBeTruthy();
    expect(screen.getByRole('button', { name: /deny refactor provider routing/i }).hasAttribute('disabled')).toBe(
      true
    );

    await act(async () => {
      resolveDecision?.();
      await decisionPromise;
    });
  });

  it('announces success and re-fetches after daemon confirms decision', async () => {
    const initial = fixtureMissionList();
    const afterApprove: MissionListResult = {
      ...initial,
      pendingApprovals: initial.pendingApprovals.filter((a) => a.id !== 'fx-appr-2')
    };
    const missionList = vi.fn().mockResolvedValue(afterApprove);
    const missionApprovalDecision = vi.fn().mockResolvedValue(undefined);
    const bridge = { missionList, missionApprovalDecision } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    useMissionsStore.setState({ data: initial, loading: false, error: null });
    const loadSpy = vi.spyOn(useMissionsStore.getState(), 'load');

    renderMissions();

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /deny refactor provider routing/i }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(missionApprovalDecision).toHaveBeenCalledWith('fx-appr-2', 'deny');
    expect(loadSpy.mock.calls.length).toBeGreaterThanOrEqual(2);
    const live = document.querySelector('[aria-live="assertive"]');
    expect(live?.textContent).toMatch(/denied: refactor provider routing/i);
  });

  it('shows decision-failed banner with daemon error text', async () => {
    const initial = fixtureMissionList();
    const missionList = vi.fn().mockResolvedValue(initial);
    const missionApprovalDecision = vi.fn().mockRejectedValue(new Error('RPC denied by policy'));
    const bridge = { missionList, missionApprovalDecision } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    stubLoad(() => useMissionsStore.setState({ data: initial, loading: false, error: null }));
    useMissionsStore.setState({ data: initial, loading: false, error: null });

    renderMissions();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /deny refactor provider routing/i }));
    });

    expect(screen.getByRole('alert').textContent).toContain('RPC denied by policy');
  });

  it('starts approval poll and clears on unmount; skips refresh while hidden', async () => {
    vi.useFakeTimers();
    const loadImpl = vi.fn().mockResolvedValue(undefined);
    useMissionsStore.setState({ load: loadImpl });
    const fx = fixtureMissionList();
    useShellStore.setState({ fixtureMode: true });
    useMissionsStore.setState({ data: fx, loading: false, error: null });

    const { unmount } = renderMissions();
    const callsAfterMount = loadImpl.mock.calls.length;

    await act(async () => {
      vi.advanceTimersByTime(30_000);
    });
    expect(loadImpl.mock.calls.length).toBeGreaterThan(callsAfterMount);

    Object.defineProperty(document, 'hidden', { configurable: true, value: true });
    const beforeHidden = loadImpl.mock.calls.length;
    await act(async () => {
      vi.advanceTimersByTime(30_000);
    });
    expect(loadImpl.mock.calls.length).toBe(beforeHidden);

    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
    unmount();
    const afterUnmount = loadImpl.mock.calls.length;
    await act(async () => {
      vi.advanceTimersByTime(60_000);
    });
    expect(loadImpl.mock.calls.length).toBe(afterUnmount);
  });
});