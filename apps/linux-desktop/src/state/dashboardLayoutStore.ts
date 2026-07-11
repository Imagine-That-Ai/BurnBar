import { create } from 'zustand';
import {
  DASHBOARD_LAYOUTS,
  type DashboardLayout,
  nextDashboardLayout,
  previousDashboardLayout,
  readPersistedDashboardLayout,
  writePersistedDashboardLayout
} from '../dashboard/dashboardLayout.js';

export type DashboardLayoutStore = {
  layout: DashboardLayout;
  setLayout: (layout: DashboardLayout) => void;
  selectNext: () => void;
  selectPrevious: () => void;
  all: readonly DashboardLayout[];
};

export const useDashboardLayoutStore = create<DashboardLayoutStore>((set, get) => ({
  layout: readPersistedDashboardLayout(),
  all: DASHBOARD_LAYOUTS,
  setLayout: (layout) => {
    writePersistedDashboardLayout(layout);
    set({ layout });
  },
  selectNext: () => {
    const next = nextDashboardLayout(get().layout);
    writePersistedDashboardLayout(next);
    set({ layout: next });
  },
  selectPrevious: () => {
    const prev = previousDashboardLayout(get().layout);
    writePersistedDashboardLayout(prev);
    set({ layout: prev });
  }
}));
