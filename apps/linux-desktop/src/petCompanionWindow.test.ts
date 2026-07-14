// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
  const invoke = vi.fn();
  const windows: { existing: MockPetWindow | null; created: MockPetWindow | null } = {
    existing: null,
    created: null
  };
  class MockPetWindow {
    static getByLabel = vi.fn(async () => windows.existing);
    readonly label: string;
    readonly options: Record<string, unknown>;
    readonly show = vi.fn(async () => {});
    readonly setFocus = vi.fn(async () => {});
    readonly setIgnoreCursorEvents = vi.fn(async (_ignore: boolean) => {});
    readonly close = vi.fn(async () => {});

    constructor(label: string, options: Record<string, unknown>) {
      this.label = label;
      this.options = options;
      windows.created = this;
    }

    async once(event: string, callback: (payload: { payload?: unknown }) => void): Promise<() => void> {
      if (event === 'tauri://created') queueMicrotask(() => callback({}));
      return () => {};
    }
  }
  return { invoke, windows, MockPetWindow };
});
vi.mock('@tauri-apps/api/core', () => ({
  invoke: (...args: unknown[]) => mocks.invoke(...args)
}));

vi.mock('@tauri-apps/api/webviewWindow', () => ({
  WebviewWindow: mocks.MockPetWindow
}));

const X11_STATUS = {
  state: 'available',
  compositor: 'GNOME/x11',
  sessionType: 'x11',
  desktop: 'GNOME',
  overlaySupported: true,
  clickThroughSupported: true,
  windowContract: 'tauri-x11-companion-v1',
  reason: 'ready',
  source: 'tauri-x11-companion-window'
};

describe('pet companion native window contract', () => {
  beforeEach(() => {
    mocks.invoke.mockReset();
    mocks.windows.existing = null;
    mocks.windows.created = null;
    (window as unknown as { __TAURI_INTERNALS__: object }).__TAURI_INTERNALS__ = {};
    mocks.invoke.mockResolvedValue(X11_STATUS);
  });

  afterEach(() => {
    delete (window as unknown as { __TAURI_INTERNALS__?: object }).__TAURI_INTERNALS__;
  });

  it('creates, shows, and focuses a constrained X11 child with pointer input enabled', async () => {
    const { openPetCompanionWindow } = await import('./petCompanionWindow.js');
    const state = await openPetCompanionWindow();
    expect(state.opened).toBe(true);
    expect(state.clickThrough).toBe(false);
    expect(mocks.windows.created?.options).toMatchObject({
      decorations: false,
      transparent: true,
      alwaysOnTop: true,
      skipTaskbar: true,
      focus: true
    });
    expect(mocks.windows.created?.show).toHaveBeenCalledTimes(1);
    expect(mocks.windows.created?.setFocus).toHaveBeenCalledTimes(1);
    expect(mocks.windows.created?.setIgnoreCursorEvents).toHaveBeenCalledWith(false);
  });

  it('refuses Wayland and unknown sessions before creating a window', async () => {
    mocks.invoke.mockResolvedValue({
      ...X11_STATUS,
      state: 'degraded',
      compositor: 'GNOME/wayland',
      sessionType: 'wayland',
      overlaySupported: false,
      clickThroughSupported: false,
      windowContract: 'none',
      reason: 'Wayland fallback'
    });
    const { openPetCompanionWindow } = await import('./petCompanionWindow.js');
    const state = await openPetCompanionWindow();
    expect(state.opened).toBe(false);
    expect(state.status.state).toBe('degraded');
    expect(mocks.windows.created).toBeNull();
  });

  it('makes click-through explicit and restores focus when turned off', async () => {
    const existing = new mocks.MockPetWindow('openburnbar-pet-companion', {});
    mocks.windows.existing = existing;
    const { setPetCompanionClickThrough } = await import('./petCompanionWindow.js');
    await expect(setPetCompanionClickThrough(true)).resolves.toMatchObject({ opened: true, clickThrough: true });
    expect(existing.setIgnoreCursorEvents).toHaveBeenCalledWith(true);

    await expect(setPetCompanionClickThrough(false)).resolves.toMatchObject({ opened: true, clickThrough: false });
    expect(existing.setIgnoreCursorEvents).toHaveBeenLastCalledWith(false);
    expect(existing.show).toHaveBeenCalledTimes(1);
    expect(existing.setFocus).toHaveBeenCalledTimes(1);
  });
});
