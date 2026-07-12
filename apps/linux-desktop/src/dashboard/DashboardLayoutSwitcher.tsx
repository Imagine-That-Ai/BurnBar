import { DASHBOARD_LAYOUT_META, DASHBOARD_LAYOUTS, type DashboardLayout } from './dashboardLayout.js';
import { useDashboardLayoutStore } from '../state/dashboardLayoutStore.js';
import './dashboard-layout.css';

export type DashboardLayoutSwitcherProps = {
  compact?: boolean;
};

export function DashboardLayoutSwitcher({ compact = false }: DashboardLayoutSwitcherProps) {
  const layout = useDashboardLayoutStore((s) => s.layout);
  const setLayout = useDashboardLayoutStore((s) => s.setLayout);

  return (
    <div
      className={`dashboard-layout-switcher${compact ? ' dashboard-layout-switcher--compact' : ''}`}
      role="group"
      aria-label="Dashboard layout"
    >
      {DASHBOARD_LAYOUTS.map((id) => {
        const meta = DASHBOARD_LAYOUT_META[id];
        const selected = id === layout;
        return (
          <button
            key={id}
            type="button"
            className={`dashboard-layout-switcher__btn${selected ? ' is-selected' : ''}`}
            aria-pressed={selected}
            title={meta.description}
            onClick={() => setLayout(id as DashboardLayout)}
          >
            <span className="dashboard-layout-switcher__glyph" aria-hidden="true">
              {meta.glyph}
            </span>
            <span className="dashboard-layout-switcher__label">{meta.displayName}</span>
          </button>
        );
      })}
    </div>
  );
}
