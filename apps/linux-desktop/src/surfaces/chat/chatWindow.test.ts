// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { CHAT_POPOUT_LABEL, isChatPopoutWindow, openChatPopoutWindow } from './chatWindow.js';

const mocks = vi.hoisted(() => {
  const windows: { existing: MockChatWindow | null; created: MockChatWindow | null } = {
    existing: null,
    created: null
  };
  let constructorCalls = 0;
  class MockChatWindow {
    static getByLabel = vi.fn(async () => windows.existing);
    readonly label: string;
    readonly options: Record<string, unknown>;
    readonly show = vi.fn(async () => {});
    readonly setFocus = vi.fn(async () => {});

    constructor(label: string, options: Record<string, unknown>) {
      constructorCalls += 1;
      this.label = label;
      this.options = options;
      windows.created = this;
    }

    async once(event: string, callback: (payload: { payload?: unknown }) => void): Promise<() => void> {
      if (event === 'tauri://created') queueMicrotask(() => callback({}));
      return () => {};
    }
  }
  return {
    windows,
    MockChatWindow,
    getConstructorCalls: () => constructorCalls,
    resetConstructorCalls: () => {
      constructorCalls = 0;
    }
  };
});

vi.mock('@tauri-apps/api/webviewWindow', () => ({
  WebviewWindow: mocks.MockChatWindow
}));

describe('Linux chat pop-out boundary', () => {
  afterEach(() => {
    window.history.replaceState({}, '', '/');
    delete (window as unknown as { __TAURI_INTERNALS__?: object }).__TAURI_INTERNALS__;
    mocks.windows.existing = null;
    mocks.windows.created = null;
    mocks.resetConstructorCalls();
    vi.restoreAllMocks();
  });

  it('recognizes only the explicit chat-popout window query', () => {
    expect(isChatPopoutWindow()).toBe(false);
    window.history.replaceState({}, '', '/?window=chat-popout#/chat');
    expect(isChatPopoutWindow()).toBe(true);
    window.history.replaceState({}, '', '/?window=chat-popout#/settings');
    expect(isChatPopoutWindow()).toBe(false);
  });

  it('opens a named browser fallback without claiming native support', async () => {
    const focus = vi.fn();
    const open = vi.spyOn(window, 'open').mockReturnValue({ focus } as unknown as Window);
    await expect(openChatPopoutWindow()).resolves.toBe(true);
    expect(open).toHaveBeenCalledWith(
      expect.stringContaining('window=chat-popout'),
      CHAT_POPOUT_LABEL,
      expect.stringContaining('width=1100')
    );
    expect(focus).toHaveBeenCalledOnce();
  });

  it('reports blocked browser pop-ups instead of silently dropping the action', async () => {
    vi.spyOn(window, 'open').mockReturnValue(null);
    await expect(openChatPopoutWindow()).resolves.toBe(false);
  });

  it('creates, shows, and focuses a native child after its lifecycle event', async () => {
    (window as unknown as { __TAURI_INTERNALS__: object }).__TAURI_INTERNALS__ = {};
    const state = await openChatPopoutWindow();
    expect(state).toBe(true);
    expect(mocks.windows.created?.options).toMatchObject({
      width: 1100,
      height: 760,
      minWidth: 780,
      minHeight: 560,
      resizable: true
    });
    expect(mocks.windows.created?.show).toHaveBeenCalledOnce();
    expect(mocks.windows.created?.setFocus).toHaveBeenCalledOnce();
  });

  it('single-flights concurrent native opens into one child window', async () => {
    (window as unknown as { __TAURI_INTERNALS__: object }).__TAURI_INTERNALS__ = {};
    const [first, second] = await Promise.all([openChatPopoutWindow(), openChatPopoutWindow()]);
    expect(first).toBe(true);
    expect(second).toBe(true);
    expect(mocks.getConstructorCalls()).toBe(1);
  });
});
