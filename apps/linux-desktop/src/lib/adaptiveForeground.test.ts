// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import {
  ADAPTIVE_FOREGROUND_FAMILIES,
  BackdropReadabilityStabilizer,
  compositeRgb,
  contrastRatio,
  fallbackReadabilityProfile,
  profileMeetsWcag,
  relativeLuminance,
  srgbChannelToLinear,
  type BackdropReadabilityProfile
} from '@openburnbar/gl-engine/engine/readability';
import { KERNELS } from '@openburnbar/gl-engine/engine/registry';
import type { RGB } from '@openburnbar/gl-engine/engine/types';
import { applyAdaptiveForeground, fallbackProfileForSkin } from './adaptiveForeground.js';
import { resolveSkinPalette } from './resolveSkinPalette.js';

function effectiveBackground(profile: BackdropReadabilityProfile, sample: RGB): RGB {
  const family = ADAPTIVE_FOREGROUND_FAMILIES[profile.tone];
  return compositeRgb(family.scrim, sample, profile.scrimOpacity);
}

function mutedContrast(profile: BackdropReadabilityProfile, sample: RGB): number {
  const family = ADAPTIVE_FOREGROUND_FAMILIES[profile.tone];
  return contrastRatio(family.muted, effectiveBackground(profile, sample));
}

describe('adaptive foreground contrast math', () => {
  afterEach(() => {
    document.documentElement.removeAttribute('style');
    delete document.documentElement.dataset.backdropForeground;
    delete document.documentElement.dataset.backdropReadabilitySource;
  });

  it('linearizes sRGB and computes WCAG luminance endpoints', () => {
    expect(srgbChannelToLinear(0)).toBe(0);
    expect(srgbChannelToLinear(255)).toBe(1);
    expect(relativeLuminance([0, 0, 0])).toBe(0);
    expect(relativeLuminance([255, 255, 255])).toBe(1);
    expect(contrastRatio([0, 0, 0], [255, 255, 255])).toBe(21);
  });

  it('alpha-composites source over background with clamped opacity', () => {
    expect(compositeRgb([255, 0, 0], [0, 0, 255], 0.5)).toEqual([127.5, 0, 127.5]);
    expect(compositeRgb([255, 0, 0], [0, 0, 255], -1)).toEqual([0, 0, 255]);
    expect(compositeRgb([255, 0, 0], [0, 0, 255], 2)).toEqual([255, 0, 0]);
  });

  it.each([
    ['dark field', [[3, 5, 10], [26, 31, 42], [54, 65, 78]]],
    ['bright field', [[210, 222, 236], [245, 248, 252], [255, 255, 255]]],
    ['high variation', [[6, 8, 16], [112, 128, 142], [250, 252, 255]]]
  ] as const)('protects the worst spatial sample for a %s', (_name, samples) => {
    const profile = new BackdropReadabilityStabilizer().update({
      samples: samples as unknown as RGB[],
      source: 'canvas',
      nowMs: 0
    });
    expect(profileMeetsWcag(profile)).toBe(true);
    expect(Math.min(...samples.map((sample) => mutedContrast(profile, sample as RGB)))).toBeGreaterThanOrEqual(4.5);
    expect(
      Math.min(
        ...samples.map((sample) =>
          contrastRatio(
            ADAPTIVE_FOREGROUND_FAMILIES[profile.tone].accent,
            effectiveBackground(profile, sample as RGB)
          )
        )
      )
    ).toBeGreaterThanOrEqual(4.5);
  });

  it('requires a sustained preference before a non-urgent tone transition', () => {
    const stabilizer = new BackdropReadabilityStabilizer();
    expect(stabilizer.update({ samples: [[70, 70, 70]], source: 'canvas', nowMs: 0 }).tone).toBe('light');
    expect(stabilizer.update({ samples: [[185, 185, 185]], source: 'canvas', nowMs: 100 }).tone).toBe('light');
    expect(stabilizer.update({ samples: [[185, 185, 185]], source: 'canvas', nowMs: 999 }).tone).toBe('light');
    expect(stabilizer.update({ samples: [[185, 185, 185]], source: 'canvas', nowMs: 1000 }).tone).toBe('dark');
  });

  it('returns deterministic WCAG fallbacks for both skins', () => {
    for (const skin of ['editorial', 'aurora'] as const) {
      const profile = fallbackProfileForSkin(skin);
      expect(profile.source).toBe('css-fallback');
      expect(profileMeetsWcag(profile)).toBe(true);
    }
  });

  it('automatically includes every registered kernel in the palette fallback matrix', () => {
    const palettes = [resolveSkinPalette('editorial'), resolveSkinPalette('aurora')];
    expect(KERNELS.length).toBeGreaterThanOrEqual(32);
    for (const kernel of KERNELS) {
      for (const palette of palettes) {
        const profile = fallbackReadabilityProfile(palette);
        expect(profileMeetsWcag(profile), `${kernel.id}/${palette.theme}`).toBe(true);
      }
    }
  });

  it('publishes and completely removes semantic DOM tokens', () => {
    const root = document.createElement('div');
    const profile = fallbackProfileForSkin('aurora');
    const cleanup = applyAdaptiveForeground(profile, root);
    expect(root.dataset.backdropForeground).toBe(profile.tone);
    expect(root.style.getPropertyValue('--adaptive-text-primary')).toBe(profile.primary);
    expect(root.style.getPropertyValue('--adaptive-accent')).toBe(profile.accent);
    expect(root.style.getPropertyValue('--adaptive-scrim-opacity')).toBe(profile.scrimOpacity.toFixed(4));
    cleanup();
    expect(root.dataset.backdropForeground).toBeUndefined();
    expect(root.getAttribute('style')).toBe('');
  });
});
