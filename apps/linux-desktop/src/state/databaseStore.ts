import { create } from 'zustand';
import {
  fixtureDatabaseCodeContextPack,
  fixtureDatabaseCodeSearch,
  fixtureDatabaseIndexAction,
  fixtureDatabaseWorkspaceStatus
} from '../daemonFixture.js';
import {
  DATABASE_CODE_DEFAULT_RESULTS,
  DATABASE_CODE_MAX_CONTEXT_BYTES,
  DATABASE_CODE_MAX_RESULTS,
  type DatabaseCodeContextPackResult,
  type DatabaseCodeSearchResult,
  type DatabaseIndexActionResult,
  type DatabaseSnapshotResult,
  type DatabaseWorkspaceStatus
} from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

const OFFLINE_ERROR = 'Packaged shell required for live database workspace RPCs.';
const CODE_SEARCH_UNAVAILABLE = 'Code search is unavailable until the packaged shell exposes the daemon index.';
const CODE_SEARCH_EMPTY = 'Enter a code search query.';

function clampCodeLimit(limit: number | undefined, fallback = DATABASE_CODE_DEFAULT_RESULTS): number {
  const value = Number.isFinite(limit) ? Math.trunc(limit as number) : fallback;
  return Math.max(1, Math.min(DATABASE_CODE_MAX_RESULTS, value));
}

export type DatabaseActionState = {
  pending: boolean;
  error: string | null;
  result: DatabaseIndexActionResult | null;
};

export type DatabaseSnapshotActionState = {
  pending: boolean;
  error: string | null;
  result: DatabaseSnapshotResult | null;
};

export type DatabaseState = {
  workspace: DatabaseWorkspaceStatus | null;
  loading: boolean;
  error: string | null;
  indexAction: DatabaseActionState;
  watchAction: DatabaseActionState;
  snapshotAction: DatabaseSnapshotActionState;
  restoreAction: DatabaseSnapshotActionState;
  codeSearch: DatabaseCodeSearchResult | null;
  codeSearchLoading: boolean;
  codeSearchError: string | null;
  codeContextPack: DatabaseCodeContextPackResult | null;
  codeContextLoading: boolean;
  codeContextError: string | null;
  loadWorkspace(projectPath?: string): Promise<void>;
  indexProject(projectPath?: string): Promise<void>;
  watchProject(projectPath?: string): Promise<void>;
  exportSnapshot(destinationPath: string, maxBytes?: number): Promise<void>;
  restoreSnapshot(snapshotPath: string, maxBytes?: number): Promise<void>;
  searchCode(query: string, projectPath?: string, limit?: number): Promise<void>;
  buildCodeContextPack(query: string, projectPath?: string, limit?: number): Promise<void>;
  clearCodeRetrieval(): void;
};

const idleAction: DatabaseActionState = {
  pending: false,
  error: null,
  result: null
};
const idleSnapshotAction: DatabaseSnapshotActionState = {
  pending: false,
  error: null,
  result: null
};

export const useDatabaseStore = create<DatabaseState>()((set, get) => ({
  workspace: null,
  loading: false,
  error: null,
  indexAction: idleAction,
  watchAction: idleAction,
  snapshotAction: idleSnapshotAction,
  restoreAction: idleSnapshotAction,
  codeSearch: null,
  codeSearchLoading: false,
  codeSearchError: null,
  codeContextPack: null,
  codeContextLoading: false,
  codeContextError: null,

  async loadWorkspace(projectPath) {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ workspace: fixtureDatabaseWorkspaceStatus(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({ workspace: null, loading: false, error: OFFLINE_ERROR });
      return;
    }
    set({ loading: true, error: null });
    try {
      const workspace = await bridge.databaseWorkspaceStatus(projectPath);
      set({ workspace, loading: false, error: null });
    } catch (e) {
      set({
        workspace: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Failed to load database workspace status'
      });
    }
  },

  async indexProject(projectPath) {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ indexAction: { pending: false, error: null, result: fixtureDatabaseIndexAction('index') } });
      await get().loadWorkspace(projectPath);
      return;
    }
    if (!bridge) {
      set({ indexAction: { pending: false, error: OFFLINE_ERROR, result: null } });
      return;
    }
    set({ indexAction: { pending: true, error: null, result: null } });
    try {
      const result = await bridge.databaseIndexProject(projectPath);
      set({ indexAction: { pending: false, error: null, result } });
      await get().loadWorkspace(projectPath);
    } catch (e) {
      set({
        indexAction: {
          pending: false,
          error: e instanceof Error ? e.message : 'Index project failed',
          result: null
        }
      });
    }
  },

  async watchProject(projectPath) {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ watchAction: { pending: false, error: null, result: fixtureDatabaseIndexAction('watch') } });
      await get().loadWorkspace(projectPath);
      return;
    }
    if (!bridge) {
      set({ watchAction: { pending: false, error: OFFLINE_ERROR, result: null } });
      return;
    }
    set({ watchAction: { pending: true, error: null, result: null } });
    try {
      const result = await bridge.databaseWatchProject(projectPath);
      set({ watchAction: { pending: false, error: null, result } });
      await get().loadWorkspace(projectPath);
    } catch (e) {
      set({
        watchAction: {
          pending: false,
          error: e instanceof Error ? e.message : 'Watch project failed',
          result: null
        }
      });
    }
  },

  async exportSnapshot(destinationPath, maxBytes) {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode || !bridge?.databaseSnapshot) {
      set({ snapshotAction: { pending: false, error: 'Encrypted database snapshots require the packaged Linux daemon.', result: null } });
      return;
    }
    set({ snapshotAction: { pending: true, error: null, result: null } });
    try {
      const result = await bridge.databaseSnapshot(destinationPath, maxBytes);
      set({ snapshotAction: { pending: false, error: null, result } });
    } catch (e) {
      set({ snapshotAction: { pending: false, error: e instanceof Error ? e.message : 'Database snapshot export failed.', result: null } });
    }
  },

  async restoreSnapshot(snapshotPath, maxBytes) {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode || !bridge?.databaseRestore) {
      set({ restoreAction: { pending: false, error: 'Encrypted database recovery requires the packaged Linux daemon.', result: null } });
      return;
    }
    set({ restoreAction: { pending: true, error: null, result: null } });
    try {
      const result = await bridge.databaseRestore(snapshotPath, maxBytes);
      set({ restoreAction: { pending: false, error: null, result } });
      await get().loadWorkspace();
    } catch (e) {
      set({ restoreAction: { pending: false, error: e instanceof Error ? e.message : 'Database snapshot restore failed.', result: null } });
    }
  },

  async searchCode(query, projectPath, limit) {
    const normalizedQuery = query.trim();
    if (!normalizedQuery) {
      set({ codeSearch: null, codeSearchLoading: false, codeSearchError: CODE_SEARCH_EMPTY });
      return;
    }
    const { fixtureMode, bridge } = useShellStore.getState();
    const request = {
      query: normalizedQuery,
      projectPath,
      limit: clampCodeLimit(limit)
    };
    set({ codeSearchLoading: true, codeSearchError: null, codeSearch: null, codeContextPack: null, codeContextError: null });
    try {
      const result = fixtureMode
        ? fixtureDatabaseCodeSearch(request)
        : bridge?.databaseCodeSearch
          ? await bridge.databaseCodeSearch(request)
          : (() => { throw new Error(CODE_SEARCH_UNAVAILABLE); })();
      set({ codeSearch: result, codeSearchLoading: false, codeSearchError: null });
    } catch (e) {
      set({
        codeSearch: null,
        codeSearchLoading: false,
        codeSearchError: e instanceof Error ? e.message : 'Code search failed.'
      });
    }
  },

  async buildCodeContextPack(query, projectPath, limit) {
    const normalizedQuery = query.trim();
    if (!normalizedQuery) {
      set({ codeContextPack: null, codeContextLoading: false, codeContextError: CODE_SEARCH_EMPTY });
      return;
    }
    const { fixtureMode, bridge } = useShellStore.getState();
    const request = {
      query: normalizedQuery,
      projectPath,
      limit: clampCodeLimit(limit, 10),
      maxBytes: DATABASE_CODE_MAX_CONTEXT_BYTES
    };
    set({ codeContextLoading: true, codeContextError: null, codeContextPack: null });
    try {
      const result = fixtureMode
        ? fixtureDatabaseCodeContextPack(request)
        : bridge?.databaseCodeContextPack
          ? await bridge.databaseCodeContextPack(request)
          : (() => { throw new Error(CODE_SEARCH_UNAVAILABLE); })();
      set({ codeContextPack: result, codeContextLoading: false, codeContextError: null });
    } catch (e) {
      set({
        codeContextPack: null,
        codeContextLoading: false,
        codeContextError: e instanceof Error ? e.message : 'Context pack failed.'
      });
    }
  },

  clearCodeRetrieval() {
    set({
      codeSearch: null,
      codeSearchLoading: false,
      codeSearchError: null,
      codeContextPack: null,
      codeContextLoading: false,
      codeContextError: null
    });
  }
}));
