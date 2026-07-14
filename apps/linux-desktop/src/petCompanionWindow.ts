import { invoke } from '@tauri-apps/api/core';
import { WebviewWindow } from '@tauri-apps/api/webviewWindow';
import {
  decodePetCompanionStatus,
  type PetCompanionStatus
} from './tauriBridge.js';

export const PET_COMPANION_LABEL = 'openburnbar-pet-companion';

export type PetCompanionWindowState = {
  status: PetCompanionStatus;
  opened: boolean;
  clickThrough: boolean;
};

const BROWSER_STATUS: PetCompanionStatus = {
  state: 'unavailable',
  compositor: 'unknown/unknown',
  overlaySupported: false,
  clickThroughSupported: false,
  windowContract: 'none',
  reason: 'Native companion-window support requires the packaged Tauri shell.',
  source: 'browser-preview'
};

export function isPetCompanionWindow(): boolean {
  if (typeof window === 'undefined') return false;
  if (new URLSearchParams(window.location.search).get('window') !== 'pet-companion') return false;
  return window.location.hash === '#/pet' || window.location.hash.startsWith('#/pet?');
}

function petCompanionURL(): string {
  if (typeof window === 'undefined') return '?window=pet-companion#/pet';
  const url = new URL(window.location.href);
  url.search = 'window=pet-companion';
  url.hash = '/pet';
  return url.toString();
}

async function nativeStatus(): Promise<PetCompanionStatus> {
  if (typeof window === 'undefined' || !('__TAURI_INTERNALS__' in window)) {
    return BROWSER_STATUS;
  }
  return decodePetCompanionStatus(await invoke<unknown>('pet_companion_status'));
}

function unavailableState(status: PetCompanionStatus, reason: string): PetCompanionWindowState {
  return {
    status: { ...status, reason },
    opened: false,
    clickThrough: false
  };
}

async function waitForWindow(child: WebviewWindow): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    let settled = false;
    let timeout: ReturnType<typeof globalThis.setTimeout> | undefined;
    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      if (timeout !== undefined) globalThis.clearTimeout(timeout);
      callback();
    };
    void child.once('tauri://created', () => finish(resolve));
    void child.once('tauri://error', (event) =>
      finish(() => reject(new Error(String(event.payload ?? 'pet companion window failed'))))
    );
    timeout = globalThis.setTimeout(
      () => finish(() => reject(new Error('Timed out waiting for the pet companion window.'))),
      5000
    );
  });
}

/** Open/focus the constrained X11 companion window, never on Wayland. */
export async function openPetCompanionWindow(): Promise<PetCompanionWindowState> {
  let status: PetCompanionStatus;
  try {
    status = await nativeStatus();
  } catch (error) {
    return unavailableState(
      BROWSER_STATUS,
      error instanceof Error ? `Native companion status failed: ${error.message}` : 'Native companion status failed.'
    );
  }
  if (!status.overlaySupported || !status.clickThroughSupported) {
    return unavailableState(status, status.reason);
  }

  try {
    const existing = await WebviewWindow.getByLabel(PET_COMPANION_LABEL);
    if (existing) {
      await existing.show();
      await existing.setFocus();
      // A focused summon always restores input. Pass-through is an explicit
      // follow-up action so the user cannot strand the child window.
      await existing.setIgnoreCursorEvents(false);
      return { status, opened: true, clickThrough: false };
    }

    const child = new WebviewWindow(PET_COMPANION_LABEL, {
      url: petCompanionURL(),
      title: 'OpenBurnBar Companion',
      width: 340,
      height: 380,
      minWidth: 260,
      minHeight: 260,
      maxWidth: 520,
      maxHeight: 560,
      resizable: true,
      decorations: false,
      transparent: true,
      alwaysOnTop: true,
      skipTaskbar: true,
      visible: true,
      focus: true,
      center: false,
      preventOverflow: true
    });
    await waitForWindow(child);
    await child.show();
    await child.setFocus();
    await child.setIgnoreCursorEvents(false);
    return { status, opened: true, clickThrough: false };
  } catch (error) {
    return unavailableState(
      status,
      error instanceof Error ? `Native companion window failed: ${error.message}` : 'Native companion window failed.'
    );
  }
}

/** Toggle pointer pass-through only for an already-open native child. */
export async function setPetCompanionClickThrough(enabled: boolean): Promise<PetCompanionWindowState> {
  let status: PetCompanionStatus;
  try {
    status = await nativeStatus();
  } catch (error) {
    return unavailableState(
      BROWSER_STATUS,
      error instanceof Error ? `Native companion status failed: ${error.message}` : 'Native companion status failed.'
    );
  }
  if (!status.clickThroughSupported) return unavailableState(status, status.reason);
  try {
    const child = await WebviewWindow.getByLabel(PET_COMPANION_LABEL);
    if (!child) {
      return unavailableState(status, 'Open the native companion window before enabling click-through.');
    }
    await child.setIgnoreCursorEvents(enabled);
    if (!enabled) {
      await child.show();
      await child.setFocus();
    }
    return { status, opened: true, clickThrough: enabled };
  } catch (error) {
    return unavailableState(
      status,
      error instanceof Error ? `Input pass-through change failed: ${error.message}` : 'Input pass-through change failed.'
    );
  }
}

export async function closePetCompanionWindow(): Promise<boolean> {
  if (typeof window === 'undefined' || !('__TAURI_INTERNALS__' in window)) return false;
  try {
    const child = await WebviewWindow.getByLabel(PET_COMPANION_LABEL);
    if (!child) return false;
    await child.close();
    return true;
  } catch (error) {
    console.warn('linux_pet_companion_close_unavailable', error);
    return false;
  }
}
