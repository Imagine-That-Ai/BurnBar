import { describe, expect, it } from 'vitest';
import { detectPetTierFromEnv } from './petCompanion.js';

describe('detectPetTierFromEnv', () => {
  it('degrades on GNOME Wayland', () => {
    const tier = detectPetTierFromEnv({
      XDG_CURRENT_DESKTOP: 'GNOME',
      XDG_SESSION_TYPE: 'wayland'
    });
    expect(tier.tier).toBe('draggable-contained');
  });

  it('allows overlay tier elsewhere', () => {
    const tier = detectPetTierFromEnv({
      XDG_CURRENT_DESKTOP: 'KDE',
      XDG_SESSION_TYPE: 'wayland'
    });
    expect(tier.tier).toBe('overlay-pass-through');
  });
});