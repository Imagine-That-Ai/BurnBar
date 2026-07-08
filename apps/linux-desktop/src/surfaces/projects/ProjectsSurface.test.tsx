// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import { ProjectsSurface } from './ProjectsSurface.js';

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
    expect(screen.getByText('No projects indexed')).toBeTruthy();
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
});