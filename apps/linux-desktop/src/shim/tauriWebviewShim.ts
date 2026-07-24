/**
 * WebView2 bridge shim — a drop-in replacement for `@tauri-apps/api/core` and
 * `@tauri-apps/api/event` used by the Windows WebView2 host build (`vite build
 * --mode windows`, aliased in vite.config.ts). It speaks the exact
 * `LinuxShellBridge` command protocol the Linux Tauri backend serves, but over
 * `chrome.webview.postMessage` to the C# SharedUiHost dispatcher in the WinUI app:
 *
 *   renderer → host : { kind: 'invoke', id, command, args }        (Channel args → { __channel: id })
 *                     { kind: 'listen', event }
 *   host → renderer : window.__obbShimDispatch({ kind: 'invoke-result', id, ok, value|error })
 *                     window.__obbShimDispatch({ kind: 'channel', channelId, chunk })
 *                     window.__obbShimDispatch({ kind: 'event', event, payload })
 *
 * Errors are delivered as message strings; the SharedUiHost answers unknown
 * commands with "not implemented on Windows", which tauriBridge.ts's
 * isCapabilityAbsentError maps to the graceful-degrade path — the same contract
 * the real Tauri backend uses for absent capabilities.
 */

declare global {
  interface Window {
    chrome?: { webview?: { postMessage: (message: unknown) => void } };
    __obbShimDispatch?: (message: ShimInbound) => void;
    __TAURI_INTERNALS__?: Record<string, unknown>;
  }
}

type ShimInbound =
  | { kind: 'invoke-result'; id: number; ok: boolean; value?: unknown; error?: string }
  | { kind: 'channel'; channelId: number; chunk: string }
  | { kind: 'event'; event: string; payload: unknown };

type EventHandler = (event: { event: string; payload: unknown }) => void;

let nextId = 1;
const pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
const channels = new Map<number, Channel<unknown>>();
const listeners = new Map<string, Set<EventHandler>>();

// loadShellBridge() gates on this global before constructing the bridge.
window.__TAURI_INTERNALS__ = {};

function post(message: unknown): void {
  const webview = window.chrome?.webview;
  if (!webview) {
    throw new Error('WebView2 bridge unavailable (chrome.webview missing)');
  }
  webview.postMessage(message);
}

window.__obbShimDispatch = (message: ShimInbound) => {
  if (message.kind === 'invoke-result') {
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    if (message.ok) {
      entry.resolve(message.value);
    } else {
      entry.reject(new Error(message.error ?? 'unknown error'));
    }
    return;
  }
  if (message.kind === 'channel') {
    channels.get(message.channelId)?.onmessage?.(message.chunk);
    return;
  }
  if (message.kind === 'event') {
    for (const handler of listeners.get(message.event) ?? []) {
      handler({ event: message.event, payload: message.payload });
    }
  }
};

export async function invoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  const id = nextId++;
  const serialized: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args ?? {})) {
    serialized[key] = value instanceof Channel ? { __channel: value.id } : value;
  }
  const result = new Promise<T>((resolve, reject) => {
    pending.set(id, {
      resolve: (value) => resolve(value as T),
      reject,
    });
  });
  post({ kind: 'invoke', id, command, args: serialized });
  return result;
}

export class Channel<T = unknown> {
  readonly id: number;
  onmessage?: (response: T) => void;

  constructor() {
    this.id = nextId++;
    channels.set(this.id, this as Channel<unknown>);
  }
}

export function listen(event: string, handler: EventHandler): Promise<() => void> {
  let set = listeners.get(event);
  if (!set) {
    set = new Set();
    listeners.set(event, set);
  }
  set.add(handler);
  post({ kind: 'listen', event });
  return Promise.resolve(() => {
    set.delete(handler);
  });
}
