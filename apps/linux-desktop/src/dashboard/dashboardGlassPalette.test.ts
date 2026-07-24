import { afterEach, describe, expect, it } from 'vitest';
import { DASHBOARD_LAYOUTS } from './dashboardLayout.js';
import {
  applyDashboardGlassPalette,
  isThemeGlassPaletteLayout,
  themeGlassPaletteFor
} from './dashboardGlassPalette.js';

afterEach(() => {
  delete document.documentElement.dataset.dashboardGlass;
});

describe('ThemeGlassPalette contract', () => {
  it('covers every macOS dashboard layout with a complete palette', () => {
    expect(DASHBOARD_LAYOUTS.map((layout) => themeGlassPaletteFor(layout).id)).toEqual(DASHBOARD_LAYOUTS);
    for (const layout of DASHBOARD_LAYOUTS) {
      const palette = themeGlassPaletteFor(layout);
      expect(palette.tint).toBeTruthy();
      expect(palette.washTop).toBeTruthy();
      expect(palette.washBottom).toBeTruthy();
      expect(palette.rim).toBeTruthy();
    }
  });

  it('matches the macOS semantic roles for each layout', () => {
    expect(themeGlassPaletteFor('classic')).toEqual({
      id: 'classic',
      tint: 'textPrimary',
      washTop: 'textPrimary',
      washBottom: 'whimsy',
      rim: 'textPrimary'
    });
    expect(themeGlassPaletteFor('aurora')).toEqual({
      id: 'aurora',
      tint: 'amber',
      washTop: 'ember',
      washBottom: 'amber',
      rim: 'amber'
    });
    expect(themeGlassPaletteFor('nebula')).toEqual({
      id: 'nebula',
      tint: 'whimsy',
      washTop: 'whimsy',
      washBottom: 'ember',
      rim: 'whimsy'
    });
    expect(themeGlassPaletteFor('constellation')).toEqual({
      id: 'constellation',
      tint: 'frost',
      washTop: 'whimsy',
      washBottom: 'frost',
      rim: 'frost'
    });
    expect(themeGlassPaletteFor('cockpit')).toEqual({
      id: 'cockpit',
      tint: 'amber',
      washTop: 'blaze',
      washBottom: 'amber',
      rim: 'blaze'
    });
    expect(themeGlassPaletteFor('atelier')).toEqual({
      id: 'atelier',
      tint: 'frost',
      washTop: 'textPrimary',
      washBottom: 'frost',
      rim: 'frost'
    });
  });

  it('applies only the validated layout identity to the document root', () => {
    applyDashboardGlassPalette('nebula');
    expect(document.documentElement.dataset.dashboardGlass).toBe('nebula');
    expect(isThemeGlassPaletteLayout('atelier')).toBe(true);
    expect(isThemeGlassPaletteLayout('not-a-layout')).toBe(false);
    expect(isThemeGlassPaletteLayout(null)).toBe(false);
  });
});
