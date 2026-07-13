import {
  findRuntimeCapability,
  type RuntimeCapabilityEntry,
  type RuntimeCapabilityManifest,
  type RuntimeCapabilityState
} from './runtimeCapabilities.js';

export type PetTier = 'overlay-pass-through' | 'draggable-contained';

export type PetAction = 'overlay' | 'click-through' | 'summon' | 'selection';

export type PetActionCapability = {
  supported: boolean;
  state: RuntimeCapabilityState;
  reason: string;
  source: string;
};

export type PetCapabilityProbe = {
  state: RuntimeCapabilityState;
  tier: PetTier;
  compositor: string | null;
  message: string;
  substitute: string | null;
  source: string;
  previewOnly: boolean;
  actions: Record<PetAction, PetActionCapability>;
};

/**
 * Native window/input hooks required before a compositor capability can turn
 * into a real ambient companion. The current Linux shell has no such
 * companion-window contract, so the production default is all false.
 */
export type PetNativeContract = {
  overlay: boolean;
  'click-through': boolean;
};

const NO_NATIVE_CONTRACT: PetNativeContract = {
  overlay: false,
  'click-through': false
};

const UNSUPPORTED_ACTIONS: Record<Exclude<PetAction, 'overlay' | 'click-through'>, PetActionCapability> = {
  summon: {
    supported: false,
    state: 'unavailable',
    reason: 'No canonical Linux summon shortcut or native command is registered for the pet companion.',
    source: 'native-contract-inventory'
  },
  selection: {
    supported: false,
    state: 'unavailable',
    reason: 'No canonical Linux companion selection, chat, or file-drop command is registered.',
    source: 'native-contract-inventory'
  }
};

function unavailableProbe(message: string, source: string): PetCapabilityProbe {
  const unavailableAction = (reason: string): PetActionCapability => ({
    supported: false,
    state: 'unavailable',
    reason,
    source
  });
  return {
    state: 'unavailable',
    tier: 'draggable-contained',
    compositor: null,
    message,
    substitute:
      'Use the in-app contained pet preview. Overlay behavior remains disabled until a native contract is available.',
    source,
    previewOnly: true,
    actions: {
      overlay: unavailableAction(message),
      'click-through': unavailableAction(
        'Input pass-through is disabled because the runtime capability probe is unavailable.'
      ),
      ...UNSUPPORTED_ACTIONS
    }
  };
}

function overlayActions(
  entry: RuntimeCapabilityEntry,
  nativeContract: PetNativeContract
): Record<'overlay' | 'click-through', PetActionCapability> {
  const manifestAllowsOverlay = entry.state === 'available';
  const supported = manifestAllowsOverlay && nativeContract.overlay;
  const reason = !manifestAllowsOverlay
    ? entry.reason
    : supported
      ? 'The native runtime manifest and companion-window contract report the constrained X11 overlay tier.'
      : 'The compositor capability is detected, but no canonical Linux companion-window contract is wired.';
  return {
    overlay: {
      supported,
      state: supported ? 'available' : 'unavailable',
      reason,
      source: supported ? entry.source : 'native-contract-inventory'
    },
    'click-through': {
      supported: supported && nativeContract['click-through'],
      state: supported && nativeContract['click-through'] ? 'available' : 'unavailable',
      reason:
        supported && nativeContract['click-through']
          ? 'Input pass-through is enabled only for the manifest-reported companion window.'
          : 'Input pass-through is disabled until a canonical companion-window input contract exists.',
      source: supported && nativeContract['click-through'] ? entry.source : 'native-contract-inventory'
    }
  };
}

/**
 * Resolve the pet UI from the same native capability manifest that gates the
 * route. Environment variables are intentionally not used here: they are
 * useful diagnostics, but cannot prove compositor/window-manager behavior.
 */
export function probePetCapability(
  manifest: RuntimeCapabilityManifest | null,
  nativeContract: PetNativeContract = NO_NATIVE_CONTRACT
): PetCapabilityProbe {
  if (!manifest) {
    return unavailableProbe(
      'The packaged runtime capability manifest is unavailable; overlay and input pass-through are disabled.',
      'runtime-capability-probe'
    );
  }

  const entry = findRuntimeCapability(manifest, 'pet.overlay');
  if (!entry) {
    return unavailableProbe(
      'The runtime capability manifest omitted pet.overlay; overlay and input pass-through are disabled.',
      'runtime-capability-manifest'
    );
  }

  const compositor = [manifest.desktop, manifest.sessionType].filter(Boolean).join('/') || null;
  const actions = overlayActions(entry, nativeContract);
  const supported = actions.overlay.supported;
  const state: RuntimeCapabilityState = supported
    ? 'available'
    : entry.state === 'available'
      ? 'degraded'
      : entry.state;
  return {
    state,
    tier: supported ? 'overlay-pass-through' : 'draggable-contained',
    compositor,
    message: supported
      ? 'The native manifest and companion-window contract report a constrained overlay tier.'
      : entry.state === 'available'
        ? 'The compositor capability is detected, but the Linux companion-window contract is not wired; the contained fallback is active.'
        : entry.reason,
    substitute: supported ? entry.substitute : (entry.substitute ?? 'Use the contained draggable companion window.'),
    source: supported ? entry.source : entry.state === 'available' ? 'native-contract-inventory' : entry.source,
    previewOnly: false,
    actions: {
      ...actions,
      ...UNSUPPORTED_ACTIONS
    }
  };
}

/**
 * Environment classification is retained for evidence matrices only. It is
 * deliberately conservative and must not drive the packaged UI: only X11 is
 * treated as a possible overlay tier, while Wayland and unknown sessions use
 * the contained fallback until a native probe confirms otherwise.
 */
export function detectPetTierFromEnv(env: Record<string, string | undefined> = {}): {
  tier: PetTier;
  compositor: string;
  message: string;
} {
  const session = (env.XDG_SESSION_TYPE ?? 'unknown').toLowerCase();
  const desktop = (env.XDG_CURRENT_DESKTOP ?? 'unknown').toLowerCase();
  const compositor = `${desktop}/${session}`;
  if (session === 'x11') {
    return {
      tier: 'overlay-pass-through',
      compositor,
      message:
        'X11 may support the constrained overlay tier; this environment hint is not proof of click-through behavior.'
    };
  }
  return {
    tier: 'draggable-contained',
    compositor,
    message:
      'The environment hint cannot prove a safe overlay contract; use the contained draggable companion until a native probe reports support.'
  };
}
