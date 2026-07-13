// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type { LinuxShellBridge, ProjectRecord } from '../../tauriBridge.js';
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
  useShellStore.setState({ bridge: null, fixtureMode: false });
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
});
