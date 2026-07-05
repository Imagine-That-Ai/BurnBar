import { invoke } from '@tauri-apps/api/core';
import type { DaemonHealth } from './daemonClient.js';

export interface LinuxShellBridge {
  daemonHealth(): Promise<DaemonHealth>;
  openDashboard(): Promise<void>;
  quitApp(): Promise<void>;
  trayDegraded(): Promise<boolean>;
  measurePerfOperation(name: string): Promise<{ name: string; ms: number; source: string; ok: boolean; detail?: string }>;
}

export async function loadShellBridge(): Promise<LinuxShellBridge | null> {
  if (!('__TAURI_INTERNALS__' in window)) {
    return null;
  }
  return {
    daemonHealth: () => invoke<DaemonHealth>('daemon_health'),
    openDashboard: () => invoke<void>('open_dashboard'),
    quitApp: () => invoke<void>('quit_app'),
    trayDegraded: () => invoke<boolean>('tray_degraded'),
    measurePerfOperation: (name) =>
      invoke<{ name: string; ms: number; source: string; ok: boolean; detail?: string }>('measure_perf_operation', { name })
  };
}
