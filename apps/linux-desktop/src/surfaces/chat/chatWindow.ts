/**
 * Linux chat window boundary.
 *
 * Tauri owns the secondary WebView in the packaged shell. Browser preview
 * keeps a standards-based `window.open` fallback so the control is testable
 * without pretending that a tab is a native window.
 */
export const CHAT_POPOUT_LABEL = 'openburnbar-chat-popout';

// Opening can be triggered by both a toolbar click and a native notification
// in the same event turn. Keep one in-flight creation so those callers share a
// single secondary window instead of racing two WebviewWindow constructors.
let openingChatPopout: Promise<boolean> | null = null;

export function isChatPopoutWindow(): boolean {
  if (typeof window === 'undefined') return false;
  if (new URLSearchParams(window.location.search).get('window') !== 'chat-popout') return false;
  // A query token alone is not enough: a stale URL must not turn another
  // route into a chat child window and accidentally expose its controls.
  return window.location.hash === '#/chat' || window.location.hash.startsWith('#/chat?');
}

function chatPopoutURL(): string {
  if (typeof window === 'undefined') return '?window=chat-popout#/chat';
  const url = new URL(window.location.href);
  url.search = 'window=chat-popout';
  url.hash = '/chat';
  return url.toString();
}

async function waitForChatPopoutWindow(child: {
  once: (
    event: string,
    callback: (event: { payload?: unknown }) => void
  ) => Promise<() => void>;
}): Promise<void> {
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
      finish(() => reject(new Error(String(event.payload ?? 'chat pop-out failed'))))
    );
    timeout = globalThis.setTimeout(
      () => finish(() => reject(new Error('Timed out waiting for the chat pop-out window.'))),
      5000
    );
  });
}

async function openChatPopoutWindowImpl(): Promise<boolean> {
  if (typeof window === 'undefined') return false;

  if (!('__TAURI_INTERNALS__' in window)) {
    const popup = window.open(
      chatPopoutURL(),
      CHAT_POPOUT_LABEL,
      'popup,width=1100,height=760,resizable=yes'
    );
    popup?.focus?.();
    return popup !== null;
  }

  try {
    const { WebviewWindow } = await import('@tauri-apps/api/webviewWindow');
    const existing = await WebviewWindow.getByLabel(CHAT_POPOUT_LABEL);
    if (existing) {
      await existing.show();
      await existing.setFocus();
      return true;
    }
    const child = new WebviewWindow(CHAT_POPOUT_LABEL, {
      url: chatPopoutURL(),
      title: 'Chat - OpenBurnBar',
      width: 1100,
      height: 760,
      minWidth: 780,
      minHeight: 560,
      resizable: true,
      center: true
    });
    await waitForChatPopoutWindow(child);
    // Tauri defaults are host-dependent. Explicitly restore visibility and
    // focus so a notification/toolbar action never leaves the new child
    // behind the main shell on Linux window managers.
    await child.show();
    await child.setFocus();
    return true;
  } catch (error) {
    console.warn('linux_chat_popout_unavailable', error);
    return false;
  }
}

/** Open or focus one chat pop-out, preserving the single-window invariant. */
export function openChatPopoutWindow(): Promise<boolean> {
  if (openingChatPopout) return openingChatPopout;
  const opening = openChatPopoutWindowImpl();
  openingChatPopout = opening;
  void opening.then(
    () => {
      if (openingChatPopout === opening) openingChatPopout = null;
    },
    () => {
      if (openingChatPopout === opening) openingChatPopout = null;
    }
  );
  return opening;
}

/** Close only the current pop-out window; the main shell is never closed. */
export async function closeChatPopoutWindow(): Promise<boolean> {
  if (typeof window === 'undefined') return false;
  if (!('__TAURI_INTERNALS__' in window)) {
    window.close();
    return true;
  }
  try {
    const { getCurrentWebviewWindow } = await import('@tauri-apps/api/webviewWindow');
    await getCurrentWebviewWindow().close();
    return true;
  } catch (error) {
    console.warn('linux_chat_popout_close_unavailable', error);
    return false;
  }
}
