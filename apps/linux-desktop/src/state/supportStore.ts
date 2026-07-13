import { create } from 'zustand';
import { useShellStore } from './shellStore.js';
import type { AppVersionInfo, LinuxUpdateStatus } from '../tauriBridge.js';

export type ExportState = 'idle' | 'exporting' | 'success' | 'failed';

function fixtureVersionInfo(): AppVersionInfo {
  return {
    shellVersion: '0.1.0-fixture',
    daemonVersion: '0.1.0-fixture',
    packageChannel: 'deb',
    updateCheck: 'fixture-only'
  };
}

function fixtureUpdateStatus(): LinuxUpdateStatus {
  return {
    state: 'current',
    currentVersion: '0.1.0-fixture',
    latestVersion: '0.1.0-fixture',
    channel: 'prerelease',
    publishedAt: '2026-07-09T00:00:00Z',
    notes: 'Fixture status. Live builds verify the detached feed signature in native Rust.',
    instructions: {
      packageManager: 'apt',
      install: {
        id: 'install',
        label: 'Update with apt',
        instruction: 'Fixture package action.',
        command: 'sudo apt-get install --only-upgrade open-burn-bar',
        available: true,
        requiresConfirmation: true
      },
      rollback: {
        id: 'rollback',
        label: 'Roll back with apt',
        instruction: 'Fixture rollback action.',
        command: 'sudo apt-get install --allow-downgrades open-burn-bar=PREVIOUS_VERSION',
        available: true,
        requiresConfirmation: true
      },
      restart: {
        id: 'restart',
        label: 'Restart OpenBurnBar',
        instruction: 'Fixture restart action.',
        command: 'systemctl --user restart openburnbar-daemon.service',
        available: true,
        requiresConfirmation: false
      }
    }
  };
}

export type SupportStoreState = {
  versionInfo: AppVersionInfo | null;
  versionLoading: boolean;
  versionError: string | null;
  updateStatus: LinuxUpdateStatus | null;
  updateLoading: boolean;
  updateError: string | null;
  exportState: ExportState;
  exportPath: string | null;
  exportError: string | null;
  loadVersion(): Promise<void>;
  checkUpdate(): Promise<void>;
  exportDiagnostics(): Promise<void>;
  resetExport(): void;
};

export const useSupportStore = create<SupportStoreState>()((set) => ({
  versionInfo: null,
  versionLoading: false,
  versionError: null,
  updateStatus: null,
  updateLoading: false,
  updateError: null,
  exportState: 'idle',
  exportPath: null,
  exportError: null,
  resetExport() {
    set({ exportState: 'idle', exportPath: null, exportError: null });
  },
  async loadVersion() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({
        versionInfo: fixtureVersionInfo(),
        versionLoading: false,
        versionError: null,
        updateStatus: fixtureUpdateStatus(),
        updateLoading: false,
        updateError: null
      });
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
      await useSupportStore.getState().checkUpdate();
    } catch (e) {
      set({
        versionInfo: null,
        versionLoading: false,
        versionError: e instanceof Error ? e.message : 'Version request failed'
      });
    }
  },
  async checkUpdate() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ updateStatus: fixtureUpdateStatus(), updateLoading: false, updateError: null });
      return;
    }
    if (!bridge?.updateStatus) {
      set({
        updateStatus: null,
        updateLoading: false,
        updateError: 'This packaged shell does not expose the native signed-feed verifier.'
      });
      return;
    }
    set({ updateLoading: true, updateError: null });
    try {
      const updateStatus = await bridge.updateStatus();
      set({ updateStatus, updateLoading: false, updateError: null });
    } catch (e) {
      set({
        updateStatus: null,
        updateLoading: false,
        updateError: e instanceof Error ? e.message : 'Signed update check failed'
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
