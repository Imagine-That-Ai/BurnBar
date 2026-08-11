// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import { projectRouteHash, projectWorkspaceRouteHash } from '../../routes.js';
import type { LinuxShellBridge, ProjectHistoryEvent, ProjectRecord } from '../../tauriBridge.js';
import { ProjectsSurface } from './ProjectsSurface.js';

const project: ProjectRecord = {
  id: 'project-apollo',
  projectSlug: 'apollo',
  displayName: 'Apollo',
  summary: 'Controller-managed Apollo workspace.',
  status: 'healthy',
  preferredCadence: 'weekly',
  aliases: ['apollo-app'],
  automationMode: 'manual',
  reviewModelID: 'glm-5',
  scheduleHourLocal: 9,
  scheduleWeekdayLocal: 2,
  freshness: 'fresh',
  pendingQuestionCount: 1,
  openFollowupCount: 0,
  activeMissionCount: 2,
  needsOperatorAttention: true,
  ingestionSource: 'manual',
  metadata: {
    session_count_last_7d: 4,
    total_cost_last_7d: 1.25,
    total_tokens_last_7d: 1200
  }
};

function resetStores(): void {
  window.history.replaceState(null, '', '/#/projects');
  useShellStore.setState({
    bridge: null,
    fixtureMode: false,
    route: 'projects',
    routeHash: '#/projects',
    routeRevision: 0
  });
  useSystemStore.setState({
    config: null,
    db: null,
    projects: null,
    memory: null,
    loading: false,
    error: null
  });
}

describe('ProjectsSurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders populated fixture project list', () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ProjectsSurface />);
    expect(screen.getByText(/live daemon project list|fixture transcript/i)).toBeTruthy();
    expect(screen.getByText('BurnBar')).toBeTruthy();
  });
  it('shows empty copy', () => {
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ projects: [], loading: false, error: null });
    render(<ProjectsSurface />);
    expect(screen.getByText('No projects registered')).toBeTruthy();
  });

  it('shows loading skeleton', () => {
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useSystemStore.setState({ loading: true, projects: null });
    const { container } = render(<ProjectsSurface />);
    expect(container.querySelector('.system-skeleton')).toBeTruthy();
  });

  it('shows offline notice', () => {
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useSystemStore.setState({ projects: null, loading: false, error: null });
    render(<ProjectsSurface />);
    expect(screen.getByRole('status')).toBeTruthy();
  });

  it('shows error with retry', () => {
    const spy = vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({ bridge: {} as never, fixtureMode: false });
    useSystemStore.setState({ projects: null, loading: false, error: 'list failed' });
    render(<ProjectsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(spy).toHaveBeenCalled();
  });

  it('opens canonical project detail without title-derived session matching', async () => {
    const projectGet = vi.fn().mockResolvedValue(project);
    const loadProjects = vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({
      bridge: { projectGet } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    useSystemStore.setState({
      projects: [{ id: project.id, name: project.displayName, path: '', scope: 'controller', projectSlug: project.projectSlug, record: project }],
      loading: false,
      error: null
    });
    render(<ProjectsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /open details/i }));
    expect(projectGet).toHaveBeenCalledWith('apollo');
    await vi.waitFor(() => expect(screen.getByRole('heading', { name: 'Apollo' })).toBeTruthy());
    expect(screen.getByText(/daemon controller registry/i)).toBeTruthy();
    expect(screen.getByText(/4/)).toBeTruthy();
    expect(loadProjects).toHaveBeenCalled();
  });

  it('loads daemon project history and surfaces the exact latest session association', async () => {
    const projectWithSession: ProjectRecord = {
      ...project,
      metadata: {
        ...project.metadata,
        latest_conversation_session_id: 'Codex:session-apollo'
      }
    };
    const history: ProjectHistoryEvent[] = [{
      id: 'event-2',
      projectSlug: 'apollo',
      eventType: 'project_upserted',
      summary: 'Apollo registered',
      detail: 'Controller registry entry persisted.',
      recordedAt: '2026-07-14T12:00:00Z',
      sequence: 2,
      isReplay: false
    }];
    const projectGet = vi.fn().mockResolvedValue(projectWithSession);
    const projectHistory = vi.fn().mockResolvedValue(history);
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({
      bridge: { projectGet, projectHistory } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    useSystemStore.setState({
      projects: [{ id: project.id, name: project.displayName, path: '', scope: 'controller', projectSlug: project.projectSlug, record: project }],
      loading: false,
      error: null
    });

    render(<ProjectsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /open details/i }));
    await vi.waitFor(() => expect(screen.getByRole('heading', { name: 'Project history' })).toBeTruthy());
    expect(projectHistory).toHaveBeenCalledWith('apollo');
    expect(screen.getByText('Codex:session-apollo')).toBeTruthy();
    expect(screen.getByText('Apollo registered')).toBeTruthy();
    expect(screen.getByText('Project Upserted')).toBeTruthy();
  });

  it('states when project history is unavailable from an older packaged daemon', async () => {
    const projectGet = vi.fn().mockResolvedValue(project);
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({
      bridge: { projectGet } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    useSystemStore.setState({
      projects: [{ id: project.id, name: project.displayName, path: '', scope: 'controller', projectSlug: project.projectSlug, record: project }],
      loading: false,
      error: null
    });

    render(<ProjectsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /open details/i }));
    await vi.waitFor(() => expect(screen.getByRole('heading', { name: 'Project history' })).toBeTruthy());
    expect(screen.getByRole('status').textContent).toContain('unavailable');
  });

  it('registers a project only through the canonical upsert bridge', async () => {
    const projectUpsert = vi.fn().mockResolvedValue(project);
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({
      bridge: { projectGet: vi.fn(), projectUpsert } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    useSystemStore.setState({ projects: [], loading: false, error: null });
    render(<ProjectsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /register project/i }));
    fireEvent.change(screen.getByLabelText('Display name'), { target: { value: 'Apollo' } });
    fireEvent.change(screen.getByLabelText('Project slug'), { target: { value: 'apollo' } });
    fireEvent.click(screen.getByRole('button', { name: /save project/i }));
    await vi.waitFor(() => expect(projectUpsert).toHaveBeenCalled());
    expect(projectUpsert.mock.calls[0][0]).toMatchObject({
      projectSlug: 'apollo',
      displayName: 'Apollo',
      preferredCadence: 'weekly',
      automationMode: 'manual'
    });
  });

  it('requires confirmation and refreshes only after project deletion succeeds', async () => {
    const projectDelete = vi.fn().mockResolvedValue({ projectSlug: 'apollo', deleted: true });
    const loadProjects = vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
    useShellStore.setState({
      bridge: { projectGet: vi.fn().mockResolvedValue(project), projectDelete } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    useSystemStore.setState({
      projects: [{ id: project.id, name: project.displayName, path: '', scope: 'controller', projectSlug: project.projectSlug, record: project }],
      loading: false,
      error: null
    });
    render(<ProjectsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /open details/i }));
    await vi.waitFor(() => expect(screen.getByRole('heading', { name: 'Apollo' })).toBeTruthy());
    fireEvent.click(screen.getByRole('button', { name: /delete project/i }));
    await vi.waitFor(() => expect(projectDelete).toHaveBeenCalledWith('apollo'));
    expect(confirm).toHaveBeenCalledWith(expect.stringContaining('Delete project'));
    expect(loadProjects).toHaveBeenCalled();
  });

  it('keeps project detail visible and surfaces a deletion error without optimistic removal', async () => {
    const projectDelete = vi.fn().mockRejectedValue(new Error('daemon refused deletion'));
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    useShellStore.setState({
      bridge: { projectGet: vi.fn().mockResolvedValue(project), projectDelete } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    useSystemStore.setState({
      projects: [{ id: project.id, name: project.displayName, path: '', scope: 'controller', projectSlug: project.projectSlug, record: project }],
      loading: false,
      error: null
    });
    render(<ProjectsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /open details/i }));
    await vi.waitFor(() => expect(screen.getByRole('heading', { name: 'Apollo' })).toBeTruthy());
    fireEvent.click(screen.getByRole('button', { name: /delete project/i }));
    await vi.waitFor(() => expect(screen.getByRole('alert').textContent).toContain('daemon refused deletion'));
    expect(screen.getByRole('heading', { name: 'Apollo' })).toBeTruthy();
  });

  it('requires confirmation before reassigning durable references', async () => {
    const target: ProjectRecord = { ...project, id: 'project-orion', projectSlug: 'orion', displayName: 'Orion' };
    const projectReassign = vi.fn().mockResolvedValue({
      sourceProjectSlug: 'apollo',
      targetProjectSlug: 'orion',
      updatedReferenceCount: 3
    });
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
    useShellStore.setState({
      bridge: { projectGet: vi.fn().mockResolvedValue(project), projectReassign } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    useSystemStore.setState({
      projects: [
        { id: project.id, name: project.displayName, path: '', scope: 'controller', projectSlug: project.projectSlug, record: project },
        { id: target.id, name: target.displayName, path: '', scope: 'controller', projectSlug: target.projectSlug, record: target }
      ],
      loading: false,
      error: null
    });
    render(<ProjectsSurface />);
    fireEvent.click(screen.getAllByRole('button', { name: /open details/i })[0]);
    await vi.waitFor(() => expect(screen.getByRole('heading', { name: 'Apollo' })).toBeTruthy());
    fireEvent.change(screen.getByRole('combobox', { name: /reassign references to/i }), { target: { value: 'orion' } });
    fireEvent.click(screen.getByRole('button', { name: /reassign references/i }));
    await vi.waitFor(() => expect(projectReassign).toHaveBeenCalledWith('apollo', 'orion'));
    expect(confirm).toHaveBeenCalledWith(expect.stringContaining('Reassign all durable references'));
  });

  it('opens an exact project deep link and re-runs the same target on repeated navigation', async () => {
    const projectGet = vi.fn().mockResolvedValue(project);
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({
      bridge: { projectGet } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false
    });
    useSystemStore.setState({ projects: [], loading: false, error: null });
    render(<ProjectsSurface />);

    const destination = { route: 'projects' as const, hash: projectRouteHash('apollo') };
    act(() => useShellStore.getState().navigateDestination(destination, { measure: false }));
    await vi.waitFor(() => expect(projectGet).toHaveBeenCalledTimes(1));
    expect(await screen.findByRole('heading', { name: 'Apollo' })).toBeTruthy();

    act(() => useShellStore.getState().navigateDestination(destination, { measure: false }));
    await vi.waitFor(() => expect(projectGet).toHaveBeenCalledTimes(2));
  });

  it('resolves a workspace deep link only from exact authoritative metadata', async () => {
    const workspaceProject: ProjectRecord = {
      ...project,
      metadata: { ...project.metadata, workspacePath: '/home/alberto/Apollo' }
    };
    const projectGet = vi.fn().mockResolvedValue(workspaceProject);
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({
      bridge: { projectGet } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false,
      routeHash: projectWorkspaceRouteHash('/home/alberto/Apollo'),
      routeRevision: 1
    });
    useSystemStore.setState({
      projects: [{
        id: workspaceProject.id,
        name: workspaceProject.displayName,
        path: '',
        scope: 'controller',
        projectSlug: workspaceProject.projectSlug,
        record: workspaceProject
      }],
      loading: false,
      error: null
    });

    render(<ProjectsSurface />);
    await vi.waitFor(() => expect(projectGet).toHaveBeenCalledWith('apollo'));
    expect(await screen.findByRole('heading', { name: 'Apollo' })).toBeTruthy();
  });

  it('fails closed when a workspace path has no exact registered project', async () => {
    const projectGet = vi.fn();
    vi.spyOn(useSystemStore.getState(), 'loadProjects').mockImplementation(async () => {});
    useShellStore.setState({
      bridge: { projectGet } as unknown as LinuxShellBridge,
      bridgeReady: true,
      fixtureMode: false,
      routeHash: projectWorkspaceRouteHash('/home/alberto/Unknown'),
      routeRevision: 1
    });
    useSystemStore.setState({
      projects: [{
        id: project.id,
        name: project.displayName,
        path: '',
        scope: 'controller',
        projectSlug: project.projectSlug,
        record: { ...project, metadata: { workspacePath: '/home/alberto/Apollo' } }
      }],
      loading: false,
      error: null
    });

    render(<ProjectsSurface />);
    expect((await screen.findByRole('alert')).textContent).toMatch(/no longer registered/i);
    expect(projectGet).not.toHaveBeenCalled();
  });
});
