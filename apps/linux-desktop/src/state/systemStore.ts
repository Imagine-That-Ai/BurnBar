import { create } from 'zustand';
import {
  fixtureConfigSnapshot,
  fixtureDbStatus,
  fixtureMemoryBoundaries,
  fixtureProjects
} from '../daemonFixture.js';
import type {
  ConfigSnapshot,
  DbStatus,
  MemoryBoundary,
  ProjectEntry
} from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

const OFFLINE_ERROR = 'Packaged shell required for live data.';

export type SystemState = {
  config: ConfigSnapshot | null;
  db: DbStatus | null;
  projects: ProjectEntry[] | null;
  memory: MemoryBoundary[] | null;
  loading: boolean;
  error: string | null;
  loadConfig(): Promise<void>;
  loadDb(): Promise<void>;
  loadProjects(): Promise<void>;
  loadMemory(): Promise<void>;
  loadAll(): Promise<void>;
};


export const useSystemStore = create<SystemState>()((set, get) => ({
  config: null,
  db: null,
  projects: null,
  memory: null,
  loading: false,
  error: null,

  async loadConfig() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ config: fixtureConfigSnapshot(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({ config: null, loading: false, error: OFFLINE_ERROR });
      return;
    }
    set({ loading: true, error: null });
    try {
      const config = await bridge.configSnapshot();
      set({ config, loading: false, error: null });
    } catch (e) {
      set({
        config: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  },

  async loadDb() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ db: fixtureDbStatus(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({ db: null, loading: false, error: OFFLINE_ERROR });
      return;
    }
    set({ loading: true, error: null });
    try {
      const db = await bridge.dbStatus();
      set({ db, loading: false, error: null });
    } catch (e) {
      set({
        db: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  },

  async loadProjects() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ projects: fixtureProjects(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({ projects: null, loading: false, error: OFFLINE_ERROR });
      return;
    }
    set({ loading: true, error: null });
    try {
      const projects = await bridge.projectList();
      set({ projects, loading: false, error: null });
    } catch (e) {
      set({
        projects: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  },

  async loadMemory() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ memory: fixtureMemoryBoundaries(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({ memory: null, loading: false, error: OFFLINE_ERROR });
      return;
    }
    set({ loading: true, error: null });
    try {
      const memory = await bridge.memoryBoundaries();
      set({ memory, loading: false, error: null });
    } catch (e) {
      set({
        memory: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  },

  async loadAll() {
    await Promise.all([
      get().loadConfig(),
      get().loadDb(),
      get().loadProjects(),
      get().loadMemory()
    ]);
  }
}));