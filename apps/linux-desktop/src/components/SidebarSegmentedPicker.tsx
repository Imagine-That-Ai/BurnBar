export type SidebarViewMode = 'agents' | 'models';

type Props = {
  mode: SidebarViewMode;
  onModeChange: (mode: SidebarViewMode) => void;
};

/**
 * Agents / Models segmented control — mirrors macOS `Picker(.segmented)` in
 * `DashboardSidebarView.swift`.
 */
export function SidebarSegmentedPicker({ mode, onModeChange }: Props) {
  return (
    <div className="sidebar-segmented" role="group" aria-label="Sidebar view mode">
      <button
        type="button"
        className="sidebar-segmented-item"
        aria-pressed={mode === 'agents'}
        onClick={() => onModeChange('agents')}
      >
        Agents
      </button>
      <button
        type="button"
        className="sidebar-segmented-item"
        aria-pressed={mode === 'models'}
        onClick={() => onModeChange('models')}
      >
        Models
      </button>
    </div>
  );
}

export const SIDEBAR_MODE_COPY: Record<
  SidebarViewMode,
  { title: string; description: string }
> = {
  agents: {
    title: 'Agent providers',
    description: 'Scan, compare spend, and drill into model behavior from one workspace.'
  },
  models: {
    title: 'LLM Models',
    description: 'Track spend and token volume across every model your agents use.'
  }
};