import {
  fallbackReadabilityProfile,
  type BackdropReadabilityProfile,
} from '@openburnbar/gl-engine/engine/readability';
import type { ShellSkin } from '../state/shellStore.js';
import { resolveSkinPalette } from './resolveSkinPalette.js';

const ADAPTIVE_PROPERTIES = [
  '--adaptive-text-primary',
  '--adaptive-text-secondary',
  '--adaptive-text-muted',
  '--adaptive-accent',
  '--adaptive-icon',
  '--adaptive-focus',
  '--adaptive-shadow',
  '--adaptive-scrim',
  '--adaptive-scrim-opacity'
] as const;

export function fallbackProfileForSkin(skin: ShellSkin): BackdropReadabilityProfile {
  return fallbackReadabilityProfile(resolveSkinPalette(skin), 'css-fallback');
}

export function applyAdaptiveForeground(
  profile: BackdropReadabilityProfile,
  root: HTMLElement = document.documentElement
): () => void {
  root.dataset.backdropForeground = profile.tone;
  root.dataset.backdropReadabilitySource = profile.source;
  root.style.setProperty('--adaptive-text-primary', profile.primary);
  root.style.setProperty('--adaptive-text-secondary', profile.secondary);
  root.style.setProperty('--adaptive-text-muted', profile.muted);
  root.style.setProperty('--adaptive-accent', profile.accent);
  root.style.setProperty('--adaptive-icon', profile.icon);
  root.style.setProperty('--adaptive-focus', profile.focus);
  root.style.setProperty('--adaptive-shadow', profile.shadow);
  root.style.setProperty('--adaptive-scrim', profile.scrim);
  root.style.setProperty('--adaptive-scrim-opacity', profile.scrimOpacity.toFixed(4));

  return () => {
    delete root.dataset.backdropForeground;
    delete root.dataset.backdropReadabilitySource;
    for (const property of ADAPTIVE_PROPERTIES) root.style.removeProperty(property);
  };
}

export function readabilityDiagnostic(profile: BackdropReadabilityProfile): string {
  return [
    profile.tone,
    profile.source,
    profile.contrastRatio.toFixed(2),
    profile.minLuminance.toFixed(3),
    profile.maxLuminance.toFixed(3),
    profile.scrimOpacity.toFixed(3),
    profile.samplingDurationMs.toFixed(3)
  ].join(':');
}
