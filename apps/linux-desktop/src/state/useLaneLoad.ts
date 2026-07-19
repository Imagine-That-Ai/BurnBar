import { useCallback, useEffect, useRef } from 'react';
import { useShellStore } from './shellStore.js';

type IdleDeadlineLike = {
  didTimeout: boolean;
  timeRemaining(): number;
};

type IdleCallback = (deadline: IdleDeadlineLike) => void;

type IdleSchedulerWindow = Window & {
  requestIdleCallback?: (callback: IdleCallback, options?: { timeout?: number }) => number;
  cancelIdleCallback?: (handle: number) => void;
};

/**
 * The packaged WebKit renderer can resolve a daemon RPC before the second
 * animation frame used by route.navigation. Defer those first loads until
 * after that frame so the navigation mark measures route rendering rather
 * than background lane hydration. Browser previews and jsdom stay eager so
 * fixtures and unit tests retain their deterministic behavior.
 */
function shouldDeferPackagedLoad(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

function schedulePackagedLoad(task: () => void): () => void {
  let cancelled = false;
  let firstFrame: number | null = null;
  let secondFrame: number | null = null;
  let timeout: number | null = null;
  let idleHandle: number | null = null;

  const run = () => {
    if (!cancelled) task();
  };

  const queueIdle = () => {
    if (cancelled) return;
    const idleWindow = window as IdleSchedulerWindow;
    if (idleWindow.requestIdleCallback) {
      idleHandle = idleWindow.requestIdleCallback(run, { timeout: 500 });
    } else {
      timeout = window.setTimeout(run, 0);
    }
  };

  if (typeof window.requestAnimationFrame === 'function') {
    firstFrame = window.requestAnimationFrame(() => {
      if (cancelled) return;
      secondFrame = window.requestAnimationFrame(queueIdle);
    });
  } else {
    timeout = window.setTimeout(queueIdle, 0);
  }

  return () => {
    cancelled = true;
    if (firstFrame !== null) window.cancelAnimationFrame(firstFrame);
    if (secondFrame !== null) window.cancelAnimationFrame(secondFrame);
    if (timeout !== null) window.clearTimeout(timeout);
    const idleWindow = window as IdleSchedulerWindow;
    if (idleHandle !== null) idleWindow.cancelIdleCallback?.(idleHandle);
  };
}

/**
 * Mount-time data loader that re-fires when the shell bridge becomes ready.
 *
 * main.tsx renders <App/> before boot() finishes, so the bridge may still be
 * null when the first passive effect fires. Subscribing to bridgeReady ensures
 * load() is called again once the bridge is available — without this, lane
 * stores write a permanent offline error and never retry.
 */
export function useLaneLoad(load: () => Promise<void>): void {
  const bridgeReady = useShellStore((s) => s.bridgeReady);
  const dataRevision = useShellStore((s) => s.dataRevision);
  const loadRef = useRef(load);
  const stateRef = useRef({ running: false, queued: false, mounted: true });
  const pendingScheduleRef = useRef<(() => void) | null>(null);
  const revisionRef = useRef(dataRevision);
  loadRef.current = load;

  useEffect(() => {
    stateRef.current.mounted = true;
    return () => {
      stateRef.current.mounted = false;
      pendingScheduleRef.current?.();
      pendingScheduleRef.current = null;
    };
  }, []);

  const run = useCallback(async (): Promise<void> => {
    if (stateRef.current.running) {
      stateRef.current.queued = true;
      return;
    }
    stateRef.current.running = true;
    try {
      do {
        stateRef.current.queued = false;
        try {
          await loadRef.current();
        } catch {
          // Lane stores own their error state; the next daemon event retries.
        }
      } while (stateRef.current.queued && stateRef.current.mounted);
    } finally {
      stateRef.current.running = false;
    }
  }, []);

  const requestLoad = useCallback((): void => {
    if (!stateRef.current.mounted) return;
    if (stateRef.current.running) {
      stateRef.current.queued = true;
      return;
    }
    if (!shouldDeferPackagedLoad()) {
      void run();
      return;
    }
    // Keep the first packaged load alive while subscription events arrive.
    // The callback reads loadRef at execution time, so it observes the latest
    // bridge and data without restarting the animation-frame/idle queue.
    if (pendingScheduleRef.current) return;
    pendingScheduleRef.current = schedulePackagedLoad(() => {
      pendingScheduleRef.current = null;
      void run();
    });
  }, [run]);

  useEffect(() => {
    requestLoad();
  }, [bridgeReady, requestLoad]);

  useEffect(() => {
    if (revisionRef.current === dataRevision) return;
    revisionRef.current = dataRevision;
    requestLoad();
  }, [dataRevision, requestLoad]);
}
