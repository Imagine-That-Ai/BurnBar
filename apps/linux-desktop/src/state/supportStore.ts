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

// Native version/feed checks can overlap when the shell reconnects while a
// user presses "Check again". Keep only the newest response authoritative so
// an older request cannot replace fresh package guidance with stale metadata.
let versionRequestSequence = 0;
let updateRequestSequence = 0;
let exportRequestSequence = 0;

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
      packageManager: 'unknown',
      install: {
        id: 'install',
        label: 'Use your package manager',
        instruction: 'Fixture mode does not identify an owning package channel.',
        available: false,
        requiresConfirmation: true
      },
      rollback: {
        id: 'rollback',
        label: 'Rollback guidance unavailable',
        instruction: 'Fixture mode has no signed previous artifact.',
        available: false,
        requiresConfirmation: true
      },
      restart: {
        id: 'restart',
        label: 'Restart OpenBurnBar',
        instruction: 'Fixture mode cannot restart a package-owned daemon.',
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
  /** True when updateStatus is the last result and the latest check failed. */
  updateStatusStale: boolean;
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
  updateStatusStale: false,
  updateLoading: false,
  updateError: null,
  exportState: 'idle',
  exportPath: null,
  exportPreview: null,
  exportError: null,
  copyState: 'idle',
  copyError: null,
  resetExport() {
    // Invalidate an in-flight native dialog/export before clearing its UI
    // state. A late response must not repopulate a path from an old shell.
    ++exportRequestSequence;
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
    const requestID = ++versionRequestSequence;
    // A new version probe supersedes any feed probe started by the previous
    // bridge snapshot. Otherwise an old response can leave updateLoading
    // stuck or publish status for a shell/daemon pair that is no longer live.
    ++updateRequestSequence;
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({
        versionInfo: fixtureVersionInfo(),
        versionLoading: false,
        versionError: null,
        updateStatus: fixtureUpdateStatus(),
        updateStatusStale: false,
        updateLoading: false,
        updateError: null
      });
      return;
    }
    if (!bridge) {
      set({
        versionInfo: null,
        versionLoading: false,
        versionError: 'Packaged shell required for live version facts.',
        updateStatus: null,
        updateStatusStale: false,
        updateLoading: false,
        updateError: null
      });
      return;
    }
    set({ versionLoading: true, versionError: null, updateLoading: false, updateError: null });
    try {
      const versionInfo = await bridge.appVersionInfo();
      if (requestID !== versionRequestSequence) return;
      set({ versionInfo, versionLoading: false, versionError: null });
      await useSupportStore.getState().checkUpdate();
    } catch (e) {
      if (requestID !== versionRequestSequence) return;
      set({
        versionInfo: null,
        versionLoading: false,
        versionError: e instanceof Error ? e.message : 'Version request failed'
      });
    }
  },
  async checkUpdate() {
    const requestID = ++updateRequestSequence;
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ updateStatus: fixtureUpdateStatus(), updateStatusStale: false, updateLoading: false, updateError: null });
      return;
    }
    if (!bridge?.updateStatus) {
      set({
        updateStatus: null,
        updateStatusStale: false,
        updateLoading: false,
        updateError: 'This packaged shell does not expose the native signed-feed verifier.'
      });
      return;
    }
    set({ updateLoading: true, updateError: null });
    try {
      const updateStatus = await bridge.updateStatus();
      if (requestID !== updateRequestSequence) return;
      set({ updateStatus, updateStatusStale: false, updateLoading: false, updateError: null });
    } catch (e) {
      if (requestID !== updateRequestSequence) return;
      const message = e instanceof Error ? e.message : 'Signed update check failed';
      const previousStatus = useSupportStore.getState().updateStatus;
      set({
        // Keep the last signed answer visible during a transient outage, but
        // mark its feed freshness unknown so package actions stay disabled.
        updateStatus: previousStatus
          ? { ...previousStatus, feedFreshness: 'unknown', feedAgeSeconds: undefined, reason: message }
          : null,
        updateStatusStale: previousStatus !== null,
        updateLoading: false,
        updateError: message
      });
    }
  },
  async exportDiagnostics() {
    const requestID = ++exportRequestSequence;
    const { fixtureMode, bridge } = useShellStore.getState();
    const isCurrentRequest = () => {
      const currentShell = useShellStore.getState();
      return requestID === exportRequestSequence
        && currentShell.fixtureMode === fixtureMode
        && currentShell.bridge === bridge;
    };
    if (!fixtureMode && !bridge) {
      if (!isCurrentRequest()) return;
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
        if (!isCurrentRequest()) return;
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
      if (!isCurrentRequest()) return;
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
      if (!isCurrentRequest()) return;
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
