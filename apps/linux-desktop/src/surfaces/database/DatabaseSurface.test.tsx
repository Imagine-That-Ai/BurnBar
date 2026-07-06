// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import { DatabaseSurface } from './DatabaseSurface.js';

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

describe('DatabaseSurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders populated fixture db facts and migration row', () => {
    useShellStore.setState({ fixtureMode: true });
    render(<DatabaseSurface />);
    expect(screen.getByText(/fixture transcript/i)).toBeTruthy();
    expect(screen.getByText('Sealed')).toBeTruthy();
    expect(screen.getByText(/schema_v7/)).toBeTruthy();
  });

  it('shows degraded banner when SQLCipher not ok', () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({
      db: {
        sqlcipherOk: false,
        migrationVersion: 3,
        sizeBytes: 1024,
        walMode: false
      },
      loading: false,
      error: null
    });
    render(<DatabaseSurface />);
    expect(screen.getByText(/SQLCipher is not reporting/i)).toBeTruthy();
    expect(screen.getByText(/Degraded \/ locked/)).toBeTruthy();
  });

  it('shows loading skeleton', () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    useSystemStore.setState({ loading: true, db: null });
    const { container } = render(<DatabaseSurface />);
    expect(container.querySelector('.system-skeleton')).toBeTruthy();
  });

  it('shows offline notice', () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useSystemStore.setState({ db: null, loading: false, error: null });
    render(<DatabaseSurface />);
    expect(screen.getByRole('status')).toBeTruthy();
  });

  it('shows error with retry', () => {
    const spy = vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    useShellStore.setState({ bridge: {} as never, fixtureMode: false });
    useSystemStore.setState({ db: null, loading: false, error: 'db down' });
    render(<DatabaseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(spy).toHaveBeenCalled();
  });
});