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
    approvalById: {},
    questionById: {},
    resumeById: {},
    creating: false,
    createError: null
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

  it('keeps the last mission snapshot visible when a refresh fails', async () => {
    const fx = fixtureMissionList();
    let shouldFail = false;
    const load = vi.spyOn(useMissionsStore.getState(), 'load').mockImplementation(async () => {
      if (shouldFail) {
        useMissionsStore.setState({ data: null, loading: false, error: 'Daemon temporarily unavailable' });
      } else {
        useMissionsStore.setState({ data: fx, loading: false, error: null });
      }
    });
    useShellStore.setState({ fixtureMode: true });
    useMissionsStore.setState({ data: fx, loading: false, error: null });
    renderMissions();

    shouldFail = true;
    await act(async () => {
      await useMissionsStore.getState().load();
    });

    expect(screen.getByText('Port dashboard to Linux')).toBeTruthy();
    expect(screen.getByRole('alert').textContent).toContain('Showing the last mission snapshot');
    expect(screen.getByRole('alert').textContent).toContain('Daemon temporarily unavailable');

    shouldFail = false;
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /^Retry$/i }));
      await Promise.resolve();
    });

    expect(load).toHaveBeenCalled();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(screen.getByText('Port dashboard to Linux')).toBeTruthy();
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

    expect(missionApprovalDecision).toHaveBeenCalledWith('fx-mission-2', 'deny');
    expect(loadSpy.mock.calls.length).toBeGreaterThanOrEqual(2);
    const live = document.querySelector('[aria-live="assertive"]');
    expect(live?.textContent).toMatch(/denied: refactor provider routing/i);
  });

  it('renders and answers daemon-owned pending questions', async () => {
    const initial: MissionListResult = {
      missions: [],
      pendingApprovals: [],
      pendingQuestions: [{
        id: 'q-rollout',
        projectSlug: 'burnbar',
        title: 'Choose rollout lane',
        prompt: 'Which rollout lane should continue?',
        status: 'pending',
        priority: 'high',
        askedAt: '2026-07-20T10:00:00Z',
        answerPlaceholder: 'Choose a lane',
        contextSummary: 'The safe lane retains review gates.',
        evidenceRefs: ['evidence://rollout'],
        suggestedOptions: [{
          id: 'option-safe',
          title: 'Safe lane',
          detail: 'Keep review gates enabled.',
          answer: 'Continue through the safe lane.'
        }]
      }]
    };
    const afterAnswer: MissionListResult = { ...initial, pendingQuestions: [] };
    const questionAnswer = vi.fn().mockResolvedValue({
      ...initial.pendingQuestions![0],
      status: 'answered'
    });
    const missionList = vi.fn().mockResolvedValue(afterAnswer);
    const bridge = { missionList, questionAnswer } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    stubLoad(() => useMissionsStore.setState({ data: initial, loading: false, error: null }));
    useMissionsStore.setState({ data: initial, loading: false, error: null });

    renderMissions();
    expect(screen.getByRole('heading', { name: 'Pending questions' })).toBeTruthy();
    expect(screen.getByText('Which rollout lane should continue?')).toBeTruthy();
    fireEvent.click(screen.getByRole('radio', { name: /safe lane/i }));
    expect((screen.getByRole('textbox', { name: 'Answer' }) as HTMLTextAreaElement).value)
      .toBe('Continue through the safe lane.');

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Submit answer' }));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(questionAnswer).toHaveBeenCalledWith({
      questionId: 'q-rollout',
      answer: 'Continue through the safe lane.',
      selectedOptionId: 'option-safe'
    });
    expect(document.querySelector('[aria-live="assertive"]')?.textContent)
      .toMatch(/answered: choose rollout lane/i);
  });

  it('files a new mission through daemon.mission.create and reloads after success', async () => {
    const initial = fixtureMissionList();
    const missionCreate = vi.fn().mockResolvedValue({
      id: 'new-mission',
      title: 'Wire Linux mission create',
      state: 'draft',
      updatedAt: new Date().toISOString(),
      laneCount: 0,
      projectSlug: 'burnbar'
    });
    const missionList = vi.fn().mockResolvedValue(initial);
    const bridge = {
      missionCreate,
      missionList,
      projectList: vi.fn().mockResolvedValue([{ id: 'burnbar', name: 'BurnBar', path: '/tmp/BurnBar', scope: 'workspace' }])
    } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    useMissionsStore.setState({ data: initial, loading: false, error: null });

    renderMissions();
    fireEvent.click(screen.getByRole('button', { name: /file new mission/i }));
    fireEvent.change(screen.getByPlaceholderText('project-slug'), {
      target: { value: 'burnbar' }
    });
    fireEvent.change(screen.getByPlaceholderText('Mission title'), {
      target: { value: 'Wire Linux mission create' }
    });
    fireEvent.change(screen.getByPlaceholderText('What should this mission accomplish?'), {
      target: { value: 'Use the existing daemon mission create RPC.' }
    });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /^file mission$/i }));
    });

    expect(missionCreate).toHaveBeenCalledWith({
      projectSlug: 'burnbar',
      title: 'Wire Linux mission create',
      summary: 'Use the existing daemon mission create RPC.'
    });
    expect(missionList).toHaveBeenCalled();
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

  it('expands canonical packet/result/evidence detail and states health is not requested', async () => {
    const mission: MissionListResult['missions'][number] = {
      id: 'm-detail',
      title: 'Inspect mission',
      state: 'in_progress',
      updatedAt: new Date().toISOString(),
      laneCount: 1,
      summary: 'Mission summary',
      packets: [{
        id: 'packet-1', workerName: 'worker-a', objective: 'Run task', status: 'completed', metadata: {}
      }],
      results: [{
        id: 'result-1', status: 'succeeded', summary: 'Task complete', burnDelta: 0,
        createdAt: new Date().toISOString(), evidenceRefs: ['evidence.json'], metadata: {}
      }]
    };
    const list: MissionListResult = { missions: [mission], pendingApprovals: [] };
    const missionGet = vi.fn().mockResolvedValue(mission);
    const bridge = { missionList: vi.fn().mockResolvedValue(list), missionGet } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    stubLoad(() => useMissionsStore.setState({ data: list, loading: false, error: null }));
    useMissionsStore.setState({ data: list, loading: false, error: null });

    renderMissions();
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    await act(async () => {
      await Promise.resolve();
    });

    expect(missionGet).toHaveBeenCalledWith('m-detail');
    expect(screen.getByText('Packets / tasks')).toBeTruthy();
    expect(screen.getByText('Task complete')).toBeTruthy();
    expect(screen.getByText(/Evidence: evidence\.json/)).toBeTruthy();
    expect(screen.getByText('Health check not requested.')).toBeTruthy();
  });

  it('renders daemon-owned mission health and controller history when available', async () => {
    const mission: MissionListResult['missions'][number] = {
      id: 'm-health',
      title: 'Healthy mission',
      state: 'in_progress',
      updatedAt: new Date().toISOString(),
      laneCount: 1,
      summary: 'Mission summary',
      packets: [{ id: 'packet-1', workerName: 'worker-a', objective: 'Run task', status: 'running', metadata: {} }],
      results: []
    };
    const list: MissionListResult = { missions: [mission], pendingApprovals: [] };
    const missionHealth = vi.fn().mockResolvedValue({
      missionId: 'm-health',
      health: {
        status: 'healthy',
        detail: 'One packet is active.',
        checkedAt: new Date().toISOString(),
        lastActivityAt: new Date().toISOString(),
        activePacketCount: 1,
        failedResultCount: 0
      },
      history: [{
        id: 'packet:packet-1',
        kind: 'packet',
        status: 'running',
        summary: 'Worker is running.',
        occurredAt: new Date().toISOString(),
        metadata: {}
      }]
    });
    const bridge = {
      missionList: vi.fn().mockResolvedValue(list),
      missionGet: vi.fn().mockResolvedValue(mission),
      missionHealth
    } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    stubLoad(() => useMissionsStore.setState({ data: list, loading: false, error: null }));
    useMissionsStore.setState({ data: list, loading: false, error: null });

    renderMissions();
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(missionHealth).toHaveBeenCalledWith('m-health');
    expect(screen.getByText(/healthy — One packet is active\./)).toBeTruthy();
    expect(screen.getByText('Worker is running.')).toBeTruthy();
  });

  it('makes Inspect logs load and reveal the canonical mission detail', async () => {
    const mission: MissionListResult['missions'][number] = {
      id: 'm-inspect',
      title: 'Inspectable mission',
      state: 'in_progress',
      updatedAt: new Date().toISOString(),
      laneCount: 1,
      summary: 'Mission detail summary',
      packets: [],
      results: []
    };
    const list: MissionListResult = { missions: [mission], pendingApprovals: [] };
    const missionGet = vi.fn().mockResolvedValue(mission);
    const bridge = { missionList: vi.fn().mockResolvedValue(list), missionGet } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    stubLoad(() => useMissionsStore.setState({ data: list, loading: false, error: null }));
    useMissionsStore.setState({ data: list, loading: false, error: null });

    renderMissions();
    fireEvent.click(screen.getByRole('button', { name: 'Inspect logs' }));
    await act(async () => {
      await Promise.resolve();
    });

    expect(missionGet).toHaveBeenCalledWith('m-inspect');
    expect(screen.getByText('Packets / tasks')).toBeTruthy();
    expect(screen.getByText('Mission detail summary')).toBeTruthy();
  });

  it('requires confirmation and calls canonical mission.cancel', async () => {
    const mission: MissionListResult['missions'][number] = {
      id: 'm-cancel',
      title: 'Cancelable mission',
      state: 'in_progress',
      updatedAt: new Date().toISOString(),
      laneCount: 0
    };
    const list: MissionListResult = { missions: [mission], pendingApprovals: [] };
    const missionCancel = vi.fn().mockResolvedValue({ ...mission, state: 'cancelled' });
    const bridge = { missionList: vi.fn().mockResolvedValue(list), missionCancel } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    stubLoad(() => useMissionsStore.setState({ data: list, loading: false, error: null }));
    useMissionsStore.setState({ data: list, loading: false, error: null });

    renderMissions();
    fireEvent.click(screen.getByRole('button', { name: 'Details' }));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel mission' }));
    expect(screen.getByRole('button', { name: 'Confirm cancel' })).toBeTruthy();
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Confirm cancel' }));
      await Promise.resolve();
    });
    expect(missionCancel).toHaveBeenCalledWith('m-cancel', 'Cancelled from Linux mission control.');
  });

  it('dispatches a daemon-owned packet when a live mission can resume', async () => {
    const mission: MissionListResult['missions'][number] = {
      id: 'm-resume',
      title: 'Resume mission',
      state: 'blocked',
      updatedAt: new Date().toISOString(),
      laneCount: 1,
      summary: 'Recover from the latest checkpoint.'
    };
    const list: MissionListResult = { missions: [mission], pendingApprovals: [] };
    const missionResume = vi.fn().mockResolvedValue({ ...mission, state: 'dispatching' });
    const bridge = { missionList: vi.fn().mockResolvedValue(list), missionResume } as unknown as LinuxShellBridge;
    useShellStore.setState({ fixtureMode: false, bridge });
    stubLoad(() => useMissionsStore.setState({ data: list, loading: false, error: null }));
    useMissionsStore.setState({ data: list, loading: false, error: null });

    renderMissions();
    fireEvent.click(screen.getByRole('button', { name: 'Resume' }));
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(missionResume).toHaveBeenCalledWith('m-resume');
    expect(document.querySelector('[aria-live="assertive"]')?.textContent).toContain('Resumed: Resume mission');
  });
});
