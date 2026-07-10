/**
 * Linux DashboardLayout contract — mirrors macOS ThemePrimitives.DashboardLayout
 * and Windows DashboardLayout.cs raw values / storage key / default.
 */

export const DASHBOARD_LAYOUT_STORAGE_KEY = 'dashboardLayout';

export const DASHBOARD_LAYOUTS = [
  'classic',
  'aurora',
  'nebula',
  'constellation',
  'cockpit',
  'atelier'
] as const;

export type DashboardLayout = (typeof DASHBOARD_LAYOUTS)[number];

export const DEFAULT_DASHBOARD_LAYOUT: DashboardLayout = 'atelier';

export type DashboardLayoutMeta = {
  id: DashboardLayout;
  displayName: string;
  /** Approximate SF Symbol name for cross-platform parity. */
  symbolName: string;
  /** Short glyph for the Linux switcher. */
  glyph: string;
  /** Kernel-forward layouts use full-bleed backdrop as hero. */
  isKernelForward: boolean;
  description: string;
};

export const DASHBOARD_LAYOUT_META: Record<DashboardLayout, DashboardLayoutMeta> = {
  classic: {
    id: 'classic',
    displayName: 'Classic',
    symbolName: 'rectangle.grid.1x2',
    glyph: '▤',
    isKernelForward: false,
    description: 'Information-dense vertical scroll overview.'
  },
  aurora: {
    id: 'aurora',
    displayName: 'Aurora',
    symbolName: 'sun.haze',
    glyph: '◎',
    isKernelForward: false,
    description: 'Provider list + open hero field + bottom data band.'
  },
  nebula: {
    id: 'nebula',
    displayName: 'Nebula',
    symbolName: 'rectangle.grid.2x2',
    glyph: '▦',
    isKernelForward: false,
    description: 'Bento grid: providers, burn card, stage, data row.'
  },
  constellation: {
    id: 'constellation',
    displayName: 'Constellation',
    symbolName: 'sparkles',
    glyph: '✦',
    isKernelForward: true,
    description: 'Centered command column over a full swarm stage.'
  },
  cockpit: {
    id: 'cockpit',
    displayName: 'Cockpit',
    symbolName: 'gauge.with.dots.needle.67percent',
    glyph: '◉',
    isKernelForward: false,
    description: 'Mission-control grid with KPI tiles and routing stage.'
  },
  atelier: {
    id: 'atelier',
    displayName: 'Atelier',
    symbolName: 'paintpalette',
    glyph: '✧',
    isKernelForward: true,
    description: 'Full-bleed kernel-forward hero with floating glass stats.'
  }
};

export function isDashboardLayout(value: unknown): value is DashboardLayout {
  return typeof value === 'string' && (DASHBOARD_LAYOUTS as readonly string[]).includes(value);
}

export function parseDashboardLayout(raw: string | null | undefined): DashboardLayout {
  return isDashboardLayout(raw) ? raw : DEFAULT_DASHBOARD_LAYOUT;
}

export function readPersistedDashboardLayout(
  storage: Pick<Storage, 'getItem'> | null = typeof localStorage !== 'undefined' ? localStorage : null
): DashboardLayout {
  try {
    return parseDashboardLayout(storage?.getItem(DASHBOARD_LAYOUT_STORAGE_KEY));
  } catch {
    return DEFAULT_DASHBOARD_LAYOUT;
  }
}

export function writePersistedDashboardLayout(
  layout: DashboardLayout,
  storage: Pick<Storage, 'setItem'> | null = typeof localStorage !== 'undefined' ? localStorage : null
): void {
  try {
    storage?.setItem(DASHBOARD_LAYOUT_STORAGE_KEY, layout);
  } catch {
    // convenience only
  }
}

export function nextDashboardLayout(current: DashboardLayout): DashboardLayout {
  const idx = DASHBOARD_LAYOUTS.indexOf(current);
  return DASHBOARD_LAYOUTS[(idx + 1) % DASHBOARD_LAYOUTS.length]!;
}

export function previousDashboardLayout(current: DashboardLayout): DashboardLayout {
  const idx = DASHBOARD_LAYOUTS.indexOf(current);
  return DASHBOARD_LAYOUTS[(idx - 1 + DASHBOARD_LAYOUTS.length) % DASHBOARD_LAYOUTS.length]!;
}
