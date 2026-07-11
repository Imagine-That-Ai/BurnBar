// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DASHBOARD_LAYOUT_STORAGE_KEY, DASHBOARD_LAYOUTS } from './dashboardLayout.js';
import { DashboardLayoutShell } from './DashboardLayoutShell.js';
import { useDashboardLayoutStore } from '../state/dashboardLayoutStore.js';

beforeEach(() => {
  localStorage.clear();
  useDashboardLayoutStore.setState({ layout: 'atelier' });
});

afterEach(cleanup);

describe('DashboardLayoutShell', () => {
  it('renders all six layout frames', () => {
    for (const layout of DASHBOARD_LAYOUTS) {
      const { unmount } = render(
        <DashboardLayoutShell layout={layout} state="empty" showSwitcher={false} />
      );
      expect(document.querySelector(`[data-dashboard-layout="${layout}"]`)).toBeTruthy();
      unmount();
    }
  });

  it('covers empty, loading, offline, and error states', () => {
    const { rerender } = render(<DashboardLayoutShell layout="classic" state="loading" showSwitcher={false} />);
    expect(screen.getByText(/Loading overview/)).toBeTruthy();
    expect(document.querySelector('[aria-busy="true"]')).toBeTruthy();

    rerender(<DashboardLayoutShell layout="classic" state="empty" showSwitcher={false} />);
    expect(screen.getByText(/No usage yet/)).toBeTruthy();
    expect(document.querySelector('.dashboard-layout-panel--skeleton')).toBeTruthy();
    expect(screen.getByText(/Usage pulse/)).toBeTruthy();

    rerender(
      <DashboardLayoutShell
        layout="classic"
        state="offline"
        offlineSummary="Daemon offline test"
        showSwitcher={false}
      />
    );
    expect(screen.getByText(/Daemon offline test/)).toBeTruthy();

    rerender(
      <DashboardLayoutShell layout="classic" state="error" errorMessage="Boom" showSwitcher={false} />
    );
    expect(screen.getByRole('alert').textContent).toMatch(/Boom/);
  });

  it('switcher persists selection under dashboardLayout', () => {
    render(<DashboardLayoutShell layout="atelier" state="populated" />);
    const nebula = screen.getByRole('button', { name: /Nebula/i });
    fireEvent.click(nebula);
    expect(localStorage.getItem(DASHBOARD_LAYOUT_STORAGE_KEY)).toBe('nebula');
    expect(useDashboardLayoutStore.getState().layout).toBe('nebula');
  });

  it('marks kernel-forward layouts', () => {
    render(<DashboardLayoutShell layout="constellation" state="empty" showSwitcher={false} />);
    expect(document.querySelector('[data-kernel-forward="true"]')).toBeTruthy();
  });
});
