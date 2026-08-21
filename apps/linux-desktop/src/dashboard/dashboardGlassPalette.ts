import {
  DASHBOARD_LAYOUTS,
  type DashboardLayout
} from './dashboardLayout.js';

/**
 * Stable semantic color roles mirrored from macOS ThemeGlassPalette.
 * CSS resolves each role against the active Linux skin and color scheme.
 */
export type ThemeGlassColorRole =
  | 'textPrimary'
  | 'amber'
  | 'ember'
  | 'whimsy'
  | 'frost'
  | 'blaze';

export type ThemeGlassPalette = {
  id: DashboardLayout;
  tint: ThemeGlassColorRole;
  washTop: ThemeGlassColorRole;
  washBottom: ThemeGlassColorRole;
  rim: ThemeGlassColorRole;
};

const THEME_GLASS_PALETTES: Record<DashboardLayout, ThemeGlassPalette> = {
  classic: {
    id: 'classic',
    tint: 'textPrimary',
    washTop: 'textPrimary',
    washBottom: 'whimsy',
    rim: 'textPrimary'
  },
  aurora: {
    id: 'aurora',
    tint: 'amber',
    washTop: 'ember',
    washBottom: 'amber',
    rim: 'amber'
  },
  nebula: {
    id: 'nebula',
    tint: 'whimsy',
    washTop: 'whimsy',
    washBottom: 'ember',
    rim: 'whimsy'
  },
  constellation: {
    id: 'constellation',
    tint: 'frost',
    washTop: 'whimsy',
    washBottom: 'frost',
    rim: 'frost'
  },
  cockpit: {
    id: 'cockpit',
    tint: 'amber',
    washTop: 'blaze',
    washBottom: 'amber',
    rim: 'blaze'
  },
  atelier: {
    id: 'atelier',
    tint: 'frost',
    washTop: 'textPrimary',
    washBottom: 'frost',
    rim: 'frost'
  },
  stream: {
    id: 'stream',
    tint: 'frost',
    washTop: 'frost',
    washBottom: 'whimsy',
    rim: 'whimsy'
  },
  atlas: {
    id: 'atlas',
    tint: 'ember',
    washTop: 'blaze',
    washBottom: 'ember',
    rim: 'ember'
  }
};

/** Return the total, stable palette for a dashboard layout. */
export function themeGlassPaletteFor(layout: DashboardLayout): ThemeGlassPalette {
  return THEME_GLASS_PALETTES[layout];
}

/**
 * Bind the selected layout to the document root. CSS owns the actual colors,
 * which keeps skin/light-mode changes live without rebuilding React surfaces.
 */
export function applyDashboardGlassPalette(
  layout: DashboardLayout,
  root: Pick<HTMLElement, 'dataset'> | null =
    typeof document !== 'undefined' ? document.documentElement : null
): void {
  if (!root) return;
  root.dataset.dashboardGlass = themeGlassPaletteFor(layout).id;
}

/** Compile-time/runtime guard used by contract tests and callers at boundaries. */
export function isThemeGlassPaletteLayout(value: unknown): value is DashboardLayout {
  return typeof value === 'string' && (DASHBOARD_LAYOUTS as readonly string[]).includes(value);
}
