import { isKernelId } from '@openburnbar/gl-engine/engine/registry';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';

/** Persisted Linux dashboard backdrop kernel — mirrors macOS `KernelBackdropPreferences.kernelKey`. */
export const KERNEL_PREFS_KEY = 'openburnbar.linux.kernel.v1';

/** Linux dashboard default: ember swarm (macOS dynamic backdrop), not registry `constellation`. */
export const DEFAULT_LINUX_KERNEL_ID: KernelId = 'swarmEmber';

/** Cinematic dashboard pace — `DashboardToolbarAndBackdrop.swift` `motionSpeedMultiplier: 0.6`. */
export const DASHBOARD_MOTION_SPEED_MULTIPLIER = 0.6;

export function readPersistedKernelId(): KernelId {
  try {
    const raw = localStorage.getItem(KERNEL_PREFS_KEY);
    return isKernelId(raw) ? raw : DEFAULT_LINUX_KERNEL_ID;
  } catch {
    return DEFAULT_LINUX_KERNEL_ID;
  }
}

export function writePersistedKernelId(id: KernelId): void {
  try {
    localStorage.setItem(KERNEL_PREFS_KEY, id);
  } catch {
    // convenience only
  }
}