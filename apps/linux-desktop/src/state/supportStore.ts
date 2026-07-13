import { create } from 'zustand';
import { useShellStore } from './shellStore.js';
import {
  isSafeDiagnosticsPath,
  isSafeDiagnosticsPreview,
  type AppVersionInfo,
  type DiagnosticsExportPreview,
  type LinuxUpdateStatus
} from '../tauriBridge.js';

export type ExportState = 'idle' | 'exporting' | 'success' | 'failed';
export type CopyState = 'idle' | 'copying' | 'success' | 'failed';

const FIXTURE_PREVIEW: DiagnosticsExportPreview = {
  schemaVersion: 1,
  byteCount: 0,
  fileMode: '0600',
  included: [
    'shell version',
    'daemon health (ok, version, protocol, socket path)',
    'package channel and runtime facts',
    'export schema and file permissions'
  ],
  excluded: [
    'provider API keys and credentials',
    'socket auth tokens',
    'provider response payloads',
    'user session content'
  ]
};

function fixtureVersionInfo(): AppVersionInfo {
  return {
    shellVersion: '0.1.0-fixture',
    daemonVersion: '0.1.0-fixture',
    packageChannel: 'unknown',
    package: { channel: 'unknown', manager: 'unknown', evidence: 'fixture-only' },
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
  exportPreview: DiagnosticsExportPreview | null;
  exportError: string | null;
  copyState: CopyState;
  copyError: string | null;
  loadVersion(): Promise<void>;
  checkUpdate(): Promise<void>;
  exportDiagnostics(): Promise<void>;
  copyDiagnosticsPath(): Promise<void>;
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
  exportPreview: null,
  exportError: null,
  copyState: 'idle',
  copyError: null,
  resetExport() {
    set({
      exportState: 'idle',
      exportPath: null,
      exportPreview: null,
      exportError: null,
      copyState: 'idle',
      copyError: null
    });
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
        exportPreview: null,
        exportError: 'Packaged shell required to export diagnostics.'
      });
      return;
    }
    set({
      exportState: 'exporting',
      exportPath: null,
      exportPreview: null,
      exportError: null,
      copyState: 'idle',
      copyError: null
    });
    try {
      if (fixtureMode) {
        const path = '/tmp/openburnbar-diagnostics-fixture.json';
        set({
          exportState: 'success',
          exportPath: path,
          exportPreview: FIXTURE_PREVIEW,
          exportError: null,
          copyState: 'idle',
          copyError: null
        });
        return;
      }
      const result = await bridge!.exportDiagnostics();
      if (!isSafeDiagnosticsPath(result.path)) {
        throw new Error('Native diagnostics export returned an unsafe path.');
      }
      if (result.preview && !isSafeDiagnosticsPreview(result.preview)) {
        throw new Error('Native diagnostics export returned unsafe preview metadata.');
      }
      set({
        exportState: 'success',
        exportPath: result.path,
        exportPreview: result.preview ?? null,
        exportError: null,
        copyState: 'idle',
        copyError: null
      });
    } catch (e) {
      set({
        exportState: 'failed',
        exportPath: null,
        exportPreview: null,
        exportError: e instanceof Error ? e.message : 'Export failed'
      });
    }
  },
  async copyDiagnosticsPath() {
    const path = useSupportStore.getState().exportPath;
    if (!path || !isSafeDiagnosticsPath(path)) {
      set({ copyState: 'failed', copyError: 'Export a diagnostics bundle before copying its path.' });
      return;
    }
    if (typeof navigator === 'undefined' || !navigator.clipboard?.writeText) {
      set({ copyState: 'failed', copyError: 'Clipboard access is unavailable in this packaged shell.' });
      return;
    }
    set({ copyState: 'copying', copyError: null });
    try {
      await navigator.clipboard.writeText(path);
      set({ copyState: 'success', copyError: null });
    } catch {
      set({ copyState: 'failed', copyError: 'Clipboard access was denied; copy the path manually.' });
    }
  }
}));
