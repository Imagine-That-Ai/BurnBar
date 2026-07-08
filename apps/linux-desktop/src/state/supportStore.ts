import { create } from 'zustand';
import { useShellStore } from './shellStore.js';
import type { AppVersionInfo } from '../tauriBridge.js';

export type ExportState = 'idle' | 'exporting' | 'success' | 'failed';

function fixtureVersionInfo(): AppVersionInfo {
  return {
    shellVersion: '0.1.0-fixture',
    daemonVersion: '0.1.0-fixture',
    packageChannel: 'deb',
    updateCheck: 'unavailable-in-shell'
  };
}

export type SupportStoreState = {
  versionInfo: AppVersionInfo | null;
  versionLoading: boolean;
  versionError: string | null;
  exportState: ExportState;
  exportPath: string | null;
  exportError: string | null;
  loadVersion(): Promise<void>;
  exportDiagnostics(): Promise<void>;
  resetExport(): void;
};

export const useSupportStore = create<SupportStoreState>()((set) => ({
  versionInfo: null,
  versionLoading: false,
  versionError: null,
  exportState: 'idle',
  exportPath: null,
  exportError: null,
  resetExport() {
    set({ exportState: 'idle', exportPath: null, exportError: null });
  },
  async loadVersion() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ versionInfo: fixtureVersionInfo(), versionLoading: false, versionError: null });
      return;
    }
    if (!bridge) {
      set({
        versionInfo: null,
        versionLoading: false,
        versionError: 'Packaged shell required for live version facts.'
      });
      return;
    }
    set({ versionLoading: true, versionError: null });
    try {
      const versionInfo = await bridge.appVersionInfo();
      set({ versionInfo, versionLoading: false, versionError: null });
    } catch (e) {
      set({
        versionInfo: null,
        versionLoading: false,
        versionError: e instanceof Error ? e.message : 'Version request failed'
      });
    }
  },
  async exportDiagnostics() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (!fixtureMode && !bridge) {
      set({
        exportState: 'failed',
        exportPath: null,
        exportError: 'Packaged shell required to export diagnostics.'
      });
      return;
    }
    set({ exportState: 'exporting', exportPath: null, exportError: null });
    try {
      if (fixtureMode) {
        const path = '/tmp/openburnbar-diagnostics-fixture.json';
        set({ exportState: 'success', exportPath: path, exportError: null });
        return;
      }
      const result = await bridge!.exportDiagnostics();
      set({ exportState: 'success', exportPath: result.path, exportError: null });
    } catch (e) {
      set({
        exportState: 'failed',
        exportPath: null,
        exportError: e instanceof Error ? e.message : 'Export failed'
      });
    }
  }
}));