import {
  findRuntimeCapability,
  type RuntimeCapabilityEntry,
  type RuntimeCapabilityManifest,
  type RuntimeCapabilityState
} from './runtimeCapabilities.js';
import type { PetCompanionStatus } from './tauriBridge.js';

export type PetTier = 'overlay-pass-through' | 'draggable-contained';

export type PetAction = 'overlay' | 'click-through' | 'summon' | 'selection';

/**
 * Actions the Linux route can perform without a desktop-level companion
 * window. These are deliberately separate from the native actions above so
 * the UI cannot accidentally turn a contained interaction into an overlay
 * claim.
 */
export type PetContainedAction = 'summon' | 'selection';

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
  containedActions: Record<PetContainedAction, PetActionCapability>;
};

/**
 * Native window/input hooks are required before a compositor capability can
 * turn into a real ambient companion. Linux currently supplies that contract
 * only for the constrained X11 child; Wayland and unknown sessions remain
 * explicitly unavailable.
 */
export type PetNativeContract = {
  overlay: boolean;
  'click-through': boolean;
};

export function petNativeContractFromStatus(status: PetCompanionStatus | null | undefined): PetNativeContract {
  // The renderer treats this status as untrusted capability input. Require
  // the complete native contract, not only optimistic booleans, so a stale or
  // forged available Wayland status can never enable overlay controls.
  if (
    !status ||
    status.state !== 'available' ||
    status.sessionType?.toLowerCase() !== 'x11' ||
    !status.compositor.toLowerCase().endsWith('/x11') ||
    status.windowContract !== 'tauri-x11-companion-v1' ||
    status.source !== 'tauri-x11-companion-window'
  ) {
    return { overlay: false, 'click-through': false };
  }
  if (!status.overlaySupported && !status.clickThroughSupported) {
    return { overlay: false, 'click-through': false };
  }
  return {
    overlay: status.overlaySupported,
    'click-through': status.clickThroughSupported
  };
}

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

const CONTAINED_ACTIONS: Record<PetContainedAction, PetActionCapability> = {
  summon: {
    supported: true,
    state: 'available',
    reason: 'Focuses the contained pet preview in the OpenBurnBar window; it never opens a desktop overlay.',
    source: 'linux-contained-surface'
  },
  selection: {
    supported: true,
    state: 'available',
    reason:
      'Selects the contained pet preview in the OpenBurnBar window; native desktop selection remains unavailable.',
    source: 'linux-contained-surface'
  }
};

function containedActions(): Record<PetContainedAction, PetActionCapability> {
  return {
    summon: { ...CONTAINED_ACTIONS.summon },
    selection: { ...CONTAINED_ACTIONS.selection }
  };
}

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
    },
    containedActions: containedActions()
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

function summonAction(
  entry: RuntimeCapabilityEntry,
  nativeContract: PetNativeContract
): PetActionCapability {
  const supported = entry.state === 'available' && nativeContract.overlay;
  return {
    supported,
    state: supported ? 'available' : 'unavailable',
    reason: supported
      ? 'The X11 native shell registers Ctrl+Alt+Super+P to summon and focus the companion window.'
      : UNSUPPORTED_ACTIONS.summon.reason,
    source: supported ? 'tauri-x11-companion-window' : UNSUPPORTED_ACTIONS.summon.source
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
      summon: summonAction(entry, nativeContract),
      selection: UNSUPPORTED_ACTIONS.selection
    },
    containedActions: containedActions()
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
