import { useEffect } from 'react';
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
  useEffect(() => {
    void load();
  }, [load, bridgeReady]);
}
