import {
  activitySessionRouteHash,
  projectRouteHash,
  providerRouteHash
} from '../routes.js';
import { useShellStore } from '../state/shellStore.js';
import type { HermesAtom } from './richContentModel.js';

export function openHermesAtom(atom: HermesAtom): void {
  const shell = useShellStore.getState();
  switch (atom.kind) {
    case 'session':
      shell.navigateDestination({
        route: 'activity',
        hash: activitySessionRouteHash(atom.id)
      });
      return;
    case 'provider':
      shell.navigateDestination({
        route: 'providers',
        hash: providerRouteHash(atom.token)
      });
      return;
    case 'quota':
      shell.navigateDestination({
        route: 'providers',
        hash: providerRouteHash(atom.provider)
      });
      return;
    case 'project':
      shell.navigateDestination({
        route: 'projects',
        hash: projectRouteHash(atom.id)
      });
      return;
    case 'tool':
      shell.setRoute('missions');
      return;
    case 'runtime':
      shell.setRoute('chat');
      return;
    case 'model':
      // The atom contract carries a model ID but no provider identity.
      // Route to the authoritative provider/model workspace without
      // fabricating a provider selection.
      shell.setRoute('providers');
      return;
    case 'cost':
    case 'window':
    case 'tokens':
      shell.setRoute('insights');
  }
}

export async function openRichContentExternalURL(url: string): Promise<void> {
  const bridge = useShellStore.getState().bridge;
  if (!bridge?.openInboxExternalUrl) {
    throw new Error('The installed Linux shell cannot safely open this link.');
  }
  await bridge.openInboxExternalUrl(url);
}
