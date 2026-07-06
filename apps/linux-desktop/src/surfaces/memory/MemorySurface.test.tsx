// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import { MemorySurface } from './MemorySurface.js';

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
  localStorage.removeItem('openburnbar.linux.memoryReviewStatus.v1');
}

describe('MemorySurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders review inbox with filter chips and recall boundaries in fixture mode', () => {
    useShellStore.setState({ fixtureMode: true });
    const { container } = render(<MemorySurface />);
    expect(screen.getByText('Approve what to remember')).toBeTruthy();
    expect(screen.getByRole('group', { name: /memory review filter/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /pending/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /approved/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /rejected/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /^all$/i })).toBeTruthy();
    expect(screen.queryByText(/until the review inbox ships/i)).toBeNull();
    expect(container.querySelectorAll('.system-scope-chip').length).toBeGreaterThan(0);
    expect(screen.getByText(/live daemon memory boundaries|fixture transcript/i)).toBeTruthy();
  });

  it('shows empty inbox copy when fixture boundaries are empty', () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ memory: [], loading: false, error: null });
    render(<MemorySurface />);
    expect(screen.getByText('No memory items pending review')).toBeTruthy();
    expect(screen.getByText('No memory boundaries configured')).toBeTruthy();
  });

  it('shows loading skeleton', () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    useSystemStore.setState({ loading: true, memory: null });
    const { container } = render(<MemorySurface />);
    expect(container.querySelector('.system-skeleton')).toBeTruthy();
  });

  it('shows offline notice', () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useSystemStore.setState({ memory: null, loading: false, error: null });
    render(<MemorySurface />);
    expect(screen.getByRole('status')).toBeTruthy();
  });

  it('shows error with retry', () => {
    const spy = vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    useShellStore.setState({ bridge: {} as never, fixtureMode: false });
    useSystemStore.setState({ memory: null, loading: false, error: 'memory failed' });
    render(<MemorySurface />);
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(spy).toHaveBeenCalled();
  });

  it('approves a pending memory in fixture mode', () => {
    useShellStore.setState({ fixtureMode: true });
    render(<MemorySurface />);
    const row = screen.getByText(/Prefer Rust for daemon IPC/i).closest('article');
    expect(row).toBeTruthy();
    fireEvent.click(within(row!).getByRole('button', { name: /^approve$/i }));
    fireEvent.click(screen.getByRole('button', { name: /^approved$/i }));
    expect(screen.getAllByText('Approved').length).toBeGreaterThan(0);
  });
});