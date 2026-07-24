import { useEffect, useState } from 'react';
import { QuotaWorkspaceSurface } from './quota/QuotaWorkspaceSurface.js';
import { useProvidersStore } from '../state/providersStore.js';
import type { ProviderCatalog } from '../tauriBridge.js';
import { ProviderModelWorkspace } from './providers/ProviderModelWorkspace.js';

/** Quota / Subscriptions vault (macOS QuotaWorkspaceView parity). */
export function ProvidersSurface() {
  const catalog = useProvidersStore((state) => state.catalog);
  const [lastCatalog, setLastCatalog] = useState<ProviderCatalog | null>(null);

  useEffect(() => {
    // A transient daemon refresh failure should not erase a usable provider
    // workspace. Explicitly empty catalogs still clear the retained view.
    if (catalog === null) return;
    setLastCatalog(catalog.length > 0 ? catalog : null);
  }, [catalog]);

  const workspaceCatalog = catalog === null ? lastCatalog : catalog.length > 0 ? catalog : null;

  return (
    <>
      <QuotaWorkspaceSurface />
      {workspaceCatalog && workspaceCatalog.length > 0 ? <ProviderModelWorkspace providers={workspaceCatalog} /> : null}
    </>
  );
}
