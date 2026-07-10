import { useEffect, useRef } from 'react';
import { useShellStore } from './shellStore.js';

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
  loadRef.current = load;

  useEffect(() => {
    stateRef.current.mounted = true;
    return () => {
      stateRef.current.mounted = false;
    };
  }, []);

  useEffect(() => {
    const run = async (): Promise<void> => {
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
    };
    void run();
  }, [load, bridgeReady, dataRevision]);
}
