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
  'atelier',
  'stream',
  'atlas'
] as const;

export type DashboardLayout = (typeof DASHBOARD_LAYOUTS)[number];

export const DEFAULT_DASHBOARD_LAYOUT: DashboardLayout = 'aurora';

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

/**
 * Ids are opaque storage keys and stay frozen; `displayName` is what changed.
 * See the same note on the Swift enum.
 */
export const DASHBOARD_LAYOUT_META: Record<DashboardLayout, DashboardLayoutMeta> = {
  classic: {
    id: 'classic',
    displayName: 'Ledger',
    symbolName: 'list.bullet.rectangle',
    glyph: '▤',
    isKernelForward: false,
    description: 'Every row, in order — one dense ordered scroll, no hero.'
  },
  aurora: {
    id: 'aurora',
    displayName: 'Focus',
    symbolName: 'largecircle.fill.circle',
    glyph: '◎',
    isKernelForward: false,
    description: 'One number, front and centre; everything else collapses below it.'
  },
  nebula: {
    id: 'nebula',
    displayName: 'Bento',
    symbolName: 'square.grid.2x2',
    glyph: '▦',
    isKernelForward: false,
    description: 'Equal tiles, scan anywhere — a grid with no reading order.'
  },
  constellation: {
    id: 'constellation',
    displayName: 'Ask',
    symbolName: 'text.magnifyingglass',
    glyph: '✦',
    isKernelForward: true,
    description: 'Ask first, results follow — the question box leads the page.'
  },
  cockpit: {
    id: 'cockpit',
    displayName: 'Cockpit',
    symbolName: 'gauge.with.dots.needle.67percent',
    glyph: '◉',
    isKernelForward: false,
    description: 'Instruments and alarm states — gauges, routing, cache hit rate.'
  },
  atelier: {
    id: 'atelier',
    displayName: 'Canvas',
    symbolName: 'photo.artframe',
    glyph: '✧',
    isKernelForward: true,
    description: 'Ambient, for a second screen — full-bleed kernel, minimal numbers.'
  },
  stream: {
    id: 'stream',
    displayName: 'Stream',
    symbolName: 'arrow.down.right.and.arrow.up.left.circle',
    glyph: '≋',
    isKernelForward: false,
    description: 'What happened, newest first — sessions, spikes and alerts on a time axis.'
  },
  atlas: {
    id: 'atlas',
    displayName: 'Atlas',
    symbolName: 'chart.bar.xaxis',
    glyph: '▥',
    isKernelForward: false,
    description: 'Side by side, with deltas — ranked provider and model comparison.'
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
