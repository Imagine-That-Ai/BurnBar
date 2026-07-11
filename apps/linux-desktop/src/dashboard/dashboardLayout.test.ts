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
      'atelier'
    ]);
    expect(DEFAULT_DASHBOARD_LAYOUT).toBe('atelier');
    expect(DASHBOARD_LAYOUT_STORAGE_KEY).toBe('dashboardLayout');
  });

  it('marks constellation and atelier as kernel-forward', () => {
    expect(DASHBOARD_LAYOUT_META.constellation.isKernelForward).toBe(true);
    expect(DASHBOARD_LAYOUT_META.atelier.isKernelForward).toBe(true);
    expect(DASHBOARD_LAYOUT_META.classic.isKernelForward).toBe(false);
    expect(DASHBOARD_LAYOUT_META.cockpit.isKernelForward).toBe(false);
  });

  it('parses unknown raw values to default', () => {
    expect(parseDashboardLayout(undefined)).toBe('atelier');
    expect(parseDashboardLayout('not-a-layout')).toBe('atelier');
    expect(parseDashboardLayout('nebula')).toBe('nebula');
  });

  it('persists layout under dashboardLayout key', () => {
    writePersistedDashboardLayout('cockpit');
    expect(localStorage.getItem(DASHBOARD_LAYOUT_STORAGE_KEY)).toBe('cockpit');
    expect(readPersistedDashboardLayout()).toBe('cockpit');
  });

  it('cycles next/previous with wrap', () => {
    expect(nextDashboardLayout('atelier')).toBe('classic');
    expect(previousDashboardLayout('classic')).toBe('atelier');
    expect(nextDashboardLayout('classic')).toBe('aurora');
  });
});
