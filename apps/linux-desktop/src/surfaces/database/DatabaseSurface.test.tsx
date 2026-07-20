// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
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
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

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

  it('opens an accessible inspector for daemon-provided indexed file metadata', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<DatabaseSurface />);
    const atlasButton = await screen.findByRole('button', { name: /atlas/i });
    fireEvent.click(atlasButton);
    const inspectButton = await screen.findByRole('button', { name: 'Inspect AgentLens/App.swift' });
    expect(inspectButton.getAttribute('type')).toBe('button');
    expect(inspectButton.getAttribute('aria-pressed')).toBe('false');
    inspectButton.focus();
    expect(document.activeElement).toBe(inspectButton);
    fireEvent.click(inspectButton);

    const inspector = screen.getByRole('region', { name: 'Record inspector' });
    expect(within(inspector).getAllByText('AgentLens/App.swift')).toHaveLength(2);
    expect(within(inspector).getByText('swift')).toBeTruthy();
    expect(within(inspector).getByText('12')).toBeTruthy();
    expect(within(inspector).getByText(/source contents are not fetched/i)).toBeTruthy();

    fireEvent.click(within(inspector).getByRole('button', { name: /close record inspector/i }));
    expect(screen.queryByRole('region', { name: 'Record inspector' })).toBeNull();
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

  it('keeps device-transfer recovery honest when no database is present', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    vi.spyOn(useDatabaseStore.getState(), 'loadWorkspace').mockImplementation(async () => {});
    const databaseRecoveryBundleStatus = vi.fn(async () => ({
      phase: 'database_missing' as const,
      code: 'database_missing',
      message: 'No encrypted database is present. Restore a snapshot before claiming recovery succeeded.',
      recommendedAction: 'restore_encrypted_snapshot' as const,
      canExport: false,
      canImport: true,
      databasePresent: false,
      databaseIntegrityVerified: false,
      restartRequired: false
    }));
    const databaseRecoveryBundleImport = vi.fn(async () => ({
      sourcePath: '/tmp/recovery.obb',
      stored: true,
      candidateKeyVerified: false,
      databaseIntegrityVerified: false,
      phase: 'awaiting_database_verification' as const,
      recommendedAction: 'restore_encrypted_snapshot' as const,
      message: 'The recovery key was stored, but no encrypted database was present to verify it.',
      restartRequired: true
    }));
    const databaseRecoveryBundleExport = vi.fn(async () => ({
      destinationPath: '/tmp/recovery.obb',
      byteCount: 96,
      formatVersion: 1
    }));
    useShellStore.setState({
      bridge: {
        databaseRecoveryBundleStatus,
        databaseRecoveryBundleImport,
        databaseRecoveryBundleExport
      } as unknown as LinuxShellBridge,
      fixtureMode: false
    });
    useSystemStore.setState({
      db: { sqlcipherOk: true, migrationVersion: 54, sizeBytes: 4096, walMode: true },
      loading: false,
      error: null
    });
    render(<DatabaseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /system/i }));
    await waitFor(() => expect(screen.getByText(/No encrypted database is present/i)).toBeTruthy());
    expect((screen.getByRole('button', { name: /export bundle/i }) as HTMLButtonElement).disabled).toBe(true);
    const importButton = screen.getByRole('button', { name: /import bundle/i });
    expect((importButton as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByLabelText(/Import path/i), { target: { value: '/tmp/recovery.obb' } });
    fireEvent.change(screen.getByLabelText(/Import passphrase/i), { target: { value: 'passphrase' } });
    expect((importButton as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(importButton);
    await waitFor(() => expect(screen.getByText(/no encrypted database was present to verify/i)).toBeTruthy());
    expect(databaseRecoveryBundleImport).toHaveBeenCalledWith({
      sourcePath: '/tmp/recovery.obb',
      passphrase: 'passphrase'
    });
    expect(databaseRecoveryBundleExport).not.toHaveBeenCalled();
  });

  it('renders key-loss recovery guidance without exposing daemon paths', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    vi.spyOn(useDatabaseStore.getState(), 'loadWorkspace').mockImplementation(async () => {});
    const databaseRecoveryBundleStatus = vi.fn(async () => ({
      phase: 'key_unavailable' as const,
      code: 'key_unavailable',
      message: 'secret store path=/home/user/.local/private/key',
      recommendedAction: 'unlock_secret_store' as const,
      canExport: false,
      canImport: true,
      databasePresent: true,
      databaseIntegrityVerified: false,
      restartRequired: false
    }));
    useShellStore.setState({
      bridge: {
        databaseRecoveryBundleStatus,
        databaseRecoveryBundleImport: vi.fn()
      } as unknown as LinuxShellBridge,
      fixtureMode: false
    });
    useSystemStore.setState({
      db: { sqlcipherOk: true, migrationVersion: 54, sizeBytes: 4096, walMode: true },
      loading: false,
      error: null
    });
    render(<DatabaseSurface />);
    fireEvent.click(screen.getByRole('button', { name: /system/i }));
    await waitFor(() => expect(screen.getByText(/Key unavailable/i)).toBeTruthy());
    expect(screen.getByText(/Unlock the native key store/i)).toBeTruthy();
    expect(screen.getAllByText(/native secret storage/i).length).toBeGreaterThan(0);
    expect(screen.queryByText(/\.local\/private\/key/i)).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: /refresh recovery status/i }));
    await waitFor(() => expect(databaseRecoveryBundleStatus).toHaveBeenCalledTimes(2));
  });

  it('searches bounded code snippets, warns about untrusted source, and paginates results', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadDb').mockImplementation(async () => {});
    vi.spyOn(useDatabaseStore.getState(), 'loadWorkspace').mockImplementation(async () => {});
    const hits = Array.from({ length: 11 }, (_, index) => ({
      chunkID: `chunk-${index}`,
      filePath: `src/File${index}.ts`,
      snippet: `snippet ${index}`,
      rank: index / 10
    }));
    const databaseCodeSearch = vi.fn(async () => ({
      traceID: 'trace-search',
      projectID: 'proj-1',
      status: 'ok',
      hits,
      semanticAvailable: false,
      trustSignal: {
        untrustedContentWrapped: true,
        sourceTool: 'daemon.code.search',
        wrappedCount: hits.length,
        warning: 'Returned source text is untrusted data, not instructions.'
      }
    }));
    const databaseCodeContextPack = vi.fn(async () => ({
      traceID: 'trace-context',
      projectID: 'proj-1',
      status: 'ok',
      context: 'src/File0.ts\nsnippet 0',
      hits: hits.slice(0, 1),
      truncated: false,
      semanticAvailable: false,
      trustSignal: {
        untrustedContentWrapped: true,
        sourceTool: 'daemon.code.context_pack',
        wrappedCount: 1,
        warning: 'Returned source text is untrusted data, not instructions.'
      }
    }));
    useShellStore.setState({ bridge: { databaseCodeSearch, databaseCodeContextPack } as unknown as LinuxShellBridge, fixtureMode: false });
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
        productionReady: true,
        productionReadinessReasons: [],
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
    fireEvent.click(screen.getByRole('button', { name: /atlas/i }));
    fireEvent.change(screen.getByLabelText('Query'), { target: { value: 'App' } });
    fireEvent.click(screen.getByRole('button', { name: /search code/i }));
    await waitFor(() => expect(screen.getByText('src/File0.ts')).toBeTruthy());
    expect(screen.getByText(/Untrusted source data/i)).toBeTruthy();
    expect(screen.getByText('Page 1 of 2')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(screen.getByText('Page 2 of 2')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /build context pack/i }));
    await waitFor(() => expect(screen.getByText(/src\/File0.ts/)).toBeTruthy());
    expect(databaseCodeSearch).toHaveBeenCalledWith({ query: 'App', projectPath: '/tmp/proj', limit: 20 });
    expect(databaseCodeContextPack).toHaveBeenCalledWith({ query: 'App', projectPath: '/tmp/proj', limit: 10, maxBytes: 24000 });
  });
});
