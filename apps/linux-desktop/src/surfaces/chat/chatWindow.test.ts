// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { CHAT_POPOUT_LABEL, isChatPopoutWindow, openChatPopoutWindow } from './chatWindow.js';

describe('Linux chat pop-out boundary', () => {
  afterEach(() => {
    window.history.replaceState({}, '', '/');
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
});
