import { create } from 'zustand';
import {
  fixtureDatabaseIndexAction,
  fixtureDatabaseWorkspaceStatus
} from '../daemonFixture.js';
import type { DatabaseIndexActionResult, DatabaseWorkspaceStatus } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

const OFFLINE_ERROR = 'Packaged shell required for live database workspace RPCs.';

export type DatabaseActionState = {
  pending: boolean;
  error: string | null;
  result: DatabaseIndexActionResult | null;
};

export type DatabaseState = {
  workspace: DatabaseWorkspaceStatus | null;
  loading: boolean;
  error: string | null;
  indexAction: DatabaseActionState;
  watchAction: DatabaseActionState;
  loadWorkspace(projectPath?: string): Promise<void>;
  indexProject(projectPath?: string): Promise<void>;
  watchProject(projectPath?: string): Promise<void>;
};

const idleAction: DatabaseActionState = {
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
  }
}));
