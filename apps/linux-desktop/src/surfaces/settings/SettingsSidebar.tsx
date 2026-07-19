import { useMemo } from 'react';
import {
  SETTINGS_SECTIONS,
  settingsTabsMatchingQuery,
  settingsTabMeta,
  type SettingsTabId
} from './settingsTabs.js';
import { SettingsDrillRow } from './SettingsDrillRow.js';

export function SettingsSidebar({
  activeTab,
  query,
  onQueryChange,
  onSelectTab
}: {
  activeTab: SettingsTabId;
  query: string;
  onQueryChange: (value: string) => void;
  onSelectTab: (tab: SettingsTabId) => void;
}) {
  const normalizedQuery = query.trim().toLowerCase();

  const visibleTabIds = useMemo(
    () => new Set(settingsTabsMatchingQuery(normalizedQuery).map((tab) => tab.id)),
    [normalizedQuery]
  );

  const home = settingsTabMeta('home');
  const showHome = visibleTabIds.has('home');

  return (
    <aside className="settings-sidebar" aria-label="Settings sections">
      <div className="settings-command-bar">
        <span className="settings-command-icon" aria-hidden="true">
          ⌕
        </span>
        <input
          type="search"
          className="settings-command-input"
          value={query}
          onChange={(ev) => onQueryChange(ev.target.value)}
          placeholder="Search settings…"
          aria-label="Search settings"
        />
        {query ? (
          <button
            type="button"
            className="settings-command-clear"
            aria-label="Clear search"
            onClick={() => onQueryChange('')}
          >
            ×
          </button>
        ) : null}
      </div>

      <nav className="settings-sidebar-nav">
        {normalizedQuery && visibleTabIds.size === 0 ? (
          <p className="muted settings-search-empty" role="status">
            No settings match “{query.trim()}”.
          </p>
        ) : null}
        {showHome ? (
          <div className="settings-sidebar-block">
            <SettingsDrillRow
              iconGlyph={home.iconGlyph}
              iconTint={home.iconTint}
              title={home.title}
              subtitle={home.subtitle}
              active={activeTab === 'home'}
              onActivate={() => onSelectTab('home')}
            />
          </div>
        ) : null}

        {SETTINGS_SECTIONS.map((section) => {
          const tabs = section.tabIds
            .map((id) => settingsTabMeta(id))
            .filter((tab) => visibleTabIds.has(tab.id));
          if (tabs.length === 0) return null;
          return (
            <div key={section.id} className="settings-sidebar-block">
              <p className="settings-sidebar-section-label">{section.title}</p>
              <div className="settings-sidebar-section-rows">
                {tabs.map((tab) => (
                  <SettingsDrillRow
                    key={tab.id}
                    iconGlyph={tab.iconGlyph}
                    iconTint={tab.iconTint}
                    title={tab.title}
                    subtitle={tab.subtitle}
                    active={activeTab === tab.id}
                    onActivate={() => onSelectTab(tab.id)}
                  />
                ))}
              </div>
            </div>
          );
        })}
      </nav>
    </aside>
  );
}
