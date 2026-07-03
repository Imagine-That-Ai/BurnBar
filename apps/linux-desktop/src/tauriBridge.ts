import { invoke } from '@tauri-apps/api/core';
import type { DaemonHealth } from './daemonClient.js';

export interface LinuxShellBridge {
  daemonHealth(): Promise<DaemonHealth>;
  openDashboard(): Promise<void>;
  quitApp(): Promise<void>;
  trayDegraded(): Promise<boolean>;
}

export async function loadShellBridge(): Promise<LinuxShellBridge | null> {
  if (!('__TAURI_INTERNALS__' in window)) {
    return null;
  }
  return {
    daemonHealth: () => invoke<DaemonHealth>('daemon_health'),
    openDashboard: () => invoke<void>('open_dashboard'),
    quitApp: () => invoke<void>('quit_app'),
    trayDegraded: () => invoke<boolean>('tray_degraded')
  };
}