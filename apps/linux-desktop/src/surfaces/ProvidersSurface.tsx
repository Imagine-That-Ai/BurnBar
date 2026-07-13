import { QuotaWorkspaceSurface } from './quota/QuotaWorkspaceSurface.js';
import { useProvidersStore } from '../state/providersStore.js';
import { ProviderModelWorkspace } from './providers/ProviderModelWorkspace.js';

/** Quota / Subscriptions vault (macOS QuotaWorkspaceView parity). */
export function ProvidersSurface() {
  const catalog = useProvidersStore((state) => state.catalog);
  return (
    <>
      <QuotaWorkspaceSurface />
      {catalog && catalog.length > 0 ? <ProviderModelWorkspace providers={catalog} /> : null}
    </>
  );
}
