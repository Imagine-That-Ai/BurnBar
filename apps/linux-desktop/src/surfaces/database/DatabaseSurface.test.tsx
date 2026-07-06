// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type { LinuxShellBridge } from '../../tauriBridge.js';
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
  useDatabaseStore.setState({
    workspace: null,
    loading: false,
    error: null,
    indexAction: { pending: false, error: null, result: null },
    watchAction: { pending: false, error: null, result: null }
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

  it('renders Atlas mode from daemon code-memory workspace status', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    vi.spyOn(useDatabaseStore.getState(), 'loadWorkspace').mockImplementation(async () => {});
    useShellStore.setState({ bridge: {} as LinuxShellBridge, fixtureMode: false });
    useSystemStore.setState({
      db: { sqlcipherOk: true, migrationVersion: 54, sizeBytes: 4096, walMode: true },
      loading: false,
      error: null
    });
    useDatabaseStore.setState({
      workspace: {
        sourceLabel: 'live daemon code-memory RPCs',
        projectID: 'proj-1',
        artifactCount: 2,
        chunkCount: 8,
        symbolCount: 13,
        referenceCount: 5,
        callEdgeCount: 3,
        rejectedCount: 0,
        storageByteCount: 2048,
        storageBudgetBytes: 4096,
        storageWithinBudget: true,
        productionReady: true,
        productionReadinessReasons: [],
        parserAvailable: true,
        databaseEncrypted: true,
        hostedCodeToolsEnabled: false,
        semanticAvailable: false,
        files: [{ id: 'src/App.tsx', filePath: 'src/App.tsx', lang: 'tsx', symbolCount: 7 }],
        languages: [{ id: 'tsx', lang: 'tsx', fileCount: 1, byteCount: 2048 }],
        diagnostics: [],
        degradedReasons: []
      },
      loading: false,
      error: null
    });
    render(<DatabaseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /atlas/i }));
    expect(screen.getByText('src/App.tsx')).toBeTruthy();
    expect(screen.getAllByText('tsx').length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText(/live daemon code-memory RPCs/i)).toBeTruthy();
  });

  it('runs System mode index and poll-watch actions through the store', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    vi.spyOn(useDatabaseStore.getState(), 'loadWorkspace').mockImplementation(async () => {});
    const indexProject = vi.spyOn(useDatabaseStore.getState(), 'indexProject').mockImplementation(async () => {
      useDatabaseStore.setState({
        indexAction: {
          pending: false,
          error: null,
          result: { projectID: 'proj-1', projectRoot: '/tmp/proj', indexedFiles: 12 }
        }
      });
    });
    const watchProject = vi.spyOn(useDatabaseStore.getState(), 'watchProject').mockImplementation(async () => {
      useDatabaseStore.setState({
        watchAction: {
          pending: false,
          error: null,
          result: { projectID: 'proj-1', projectRoot: '/tmp/proj', indexedFiles: 12, watching: true, pollIntervalSeconds: 2 }
        }
      });
    });
    useShellStore.setState({ bridge: {} as LinuxShellBridge, fixtureMode: false });
    useSystemStore.setState({
      db: { sqlcipherOk: true, migrationVersion: 54, sizeBytes: 4096, walMode: true },
      loading: false,
      error: null
    });
    useDatabaseStore.setState({
      workspace: {
        sourceLabel: 'live daemon code-memory RPCs',
        projectID: 'proj-1',
        projectRoot: '/tmp/proj',
        artifactCount: 2,
        chunkCount: 8,
        symbolCount: 13,
        referenceCount: 5,
        callEdgeCount: 3,
        rejectedCount: 0,
        storageByteCount: 2048,
        storageBudgetBytes: 4096,
        storageWithinBudget: true,
        productionReady: false,
        productionReadinessReasons: ['PROJECT_CODE_MEMORY_PRODUCTION_READY=false'],
        parserAvailable: true,
        databaseEncrypted: true,
        hostedCodeToolsEnabled: false,
        semanticAvailable: false,
        files: [],
        languages: [],
        diagnostics: [],
        degradedReasons: []
      },
      loading: false,
      error: null
    });
    render(<DatabaseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /system/i }));
    fireEvent.click(screen.getByRole('button', { name: /^index project$/i }));
    fireEvent.click(screen.getByRole('button', { name: /^watch project$/i }));
    expect(indexProject).toHaveBeenCalledWith('/tmp/proj');
    expect(watchProject).toHaveBeenCalledWith('/tmp/proj');
    await waitFor(() => expect(screen.getByText(/Poll watch active/i)).toBeTruthy());
  });

  it('shows code-memory degraded reasons in Atlas mode', () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    vi.spyOn(useDatabaseStore.getState(), 'loadWorkspace').mockImplementation(async () => {});
    useShellStore.setState({ bridge: {} as LinuxShellBridge, fixtureMode: false });
    useSystemStore.setState({
      db: { sqlcipherOk: true, migrationVersion: 54, sizeBytes: 4096, walMode: true },
      loading: false,
      error: null
    });
    useDatabaseStore.setState({
      workspace: null,
      loading: false,
      error: 'Project code memory is not available. Configure OPENBURNBAR_INDEX_DATABASE_PATH.'
    });
    render(<DatabaseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /atlas/i }));
    expect(screen.getByRole('alert').textContent).toContain('OPENBURNBAR_INDEX_DATABASE_PATH');
  });
});
