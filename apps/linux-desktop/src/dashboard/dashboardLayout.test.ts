import { afterEach, describe, expect, it } from 'vitest';
import {
  DASHBOARD_LAYOUT_META,
  DASHBOARD_LAYOUT_STORAGE_KEY,
  DASHBOARD_LAYOUTS,
  DEFAULT_DASHBOARD_LAYOUT,
  nextDashboardLayout,
  parseDashboardLayout,
  previousDashboardLayout,
  readPersistedDashboardLayout,
  writePersistedDashboardLayout
} from './dashboardLayout.js';

afterEach(() => {
  try {
    localStorage.removeItem(DASHBOARD_LAYOUT_STORAGE_KEY);
  } catch {
    /* jsdom may not have storage in some runners */
  }
});

describe('DashboardLayout contract', () => {
  it('matches macOS/Windows raw values and default', () => {
    expect(DASHBOARD_LAYOUTS).toEqual([
      'classic',
      'aurora',
      'nebula',
      'constellation',
      'cockpit',
      'atelier',
      'stream',
      'atlas'
    ]);
    expect(DEFAULT_DASHBOARD_LAYOUT).toBe('aurora');
    expect(DASHBOARD_LAYOUT_STORAGE_KEY).toBe('dashboardLayout');
  });

  // The ids above are storage keys; these are the names a user reads. They were
  // renamed away from the design-phase codenames precisely so the ids could stay
  // frozen across macOS, Linux and Windows.
  it('carries the shipped display names for every id', () => {
    expect(DASHBOARD_LAYOUT_META.classic.displayName).toBe('Ledger');
    expect(DASHBOARD_LAYOUT_META.aurora.displayName).toBe('Focus');
    expect(DASHBOARD_LAYOUT_META.nebula.displayName).toBe('Bento');
    expect(DASHBOARD_LAYOUT_META.constellation.displayName).toBe('Ask');
    expect(DASHBOARD_LAYOUT_META.cockpit.displayName).toBe('Cockpit');
    expect(DASHBOARD_LAYOUT_META.atelier.displayName).toBe('Canvas');
    expect(DASHBOARD_LAYOUT_META.stream.displayName).toBe('Stream');
    expect(DASHBOARD_LAYOUT_META.atlas.displayName).toBe('Atlas');
    const names = DASHBOARD_LAYOUTS.map((id) => DASHBOARD_LAYOUT_META[id].displayName);
    expect(new Set(names).size).toBe(names.length);
  });

  it('marks constellation and atelier as kernel-forward', () => {
    expect(DASHBOARD_LAYOUT_META.constellation.isKernelForward).toBe(true);
    expect(DASHBOARD_LAYOUT_META.atelier.isKernelForward).toBe(true);
    expect(DASHBOARD_LAYOUT_META.classic.isKernelForward).toBe(false);
    expect(DASHBOARD_LAYOUT_META.cockpit.isKernelForward).toBe(false);
  });

  it('parses unknown raw values to default', () => {
    expect(parseDashboardLayout(undefined)).toBe('aurora');
    expect(parseDashboardLayout('not-a-layout')).toBe('aurora');
    expect(parseDashboardLayout('nebula')).toBe('nebula');
  });

  it('persists layout under dashboardLayout key', () => {
    writePersistedDashboardLayout('cockpit');
    expect(localStorage.getItem(DASHBOARD_LAYOUT_STORAGE_KEY)).toBe('cockpit');
    expect(readPersistedDashboardLayout()).toBe('cockpit');
  });

  it('cycles next/previous with wrap', () => {
    expect(nextDashboardLayout('atlas')).toBe('classic');
    expect(previousDashboardLayout('classic')).toBe('atlas');
    expect(nextDashboardLayout('classic')).toBe('aurora');
    expect(nextDashboardLayout('atelier')).toBe('stream');
  });
});
