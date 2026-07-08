import { useCallback, useState } from 'react';
import type { ReactNode } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import { SystemStatusSection } from '../SystemStatusSection.js';
import '../system/system.css';
import './settings.css';
import { IntegrationsSection } from './IntegrationsSection.js';
import { SettingsDetailPane } from './SettingsDetailPane.js';
import { SettingsSidebar } from './SettingsSidebar.js';
import {
  SETTINGS_TAB_STORAGE_KEY,
  readStoredSettingsTab,
  type SettingsTabId
} from './settingsTabs.js';

function SettingsSkeleton() {
  return (
    <div className="settings-split settings-split--loading" aria-busy="true">
      <div className="settings-sidebar settings-sidebar--skeleton">
        <div className="system-skeleton-line" />
        <div className="system-skeleton-line" />
      </div>
      <div className="settings-detail settings-detail--skeleton">
        <div className="system-skeleton">
          <div className="system-skeleton-line" />
          <div className="system-skeleton-line" />
        </div>
      </div>
    </div>
  );
}

export function SettingsSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const setRoute = useShellStore((s) => s.setRoute);
  const status = useDaemonStatusCopy();
  const config = useSystemStore((s) => s.config);
  const loading = useSystemStore((s) => s.loading);
  const error = useSystemStore((s) => s.error);
  const loadConfig = useSystemStore((s) => s.loadConfig);
  const [activeTab, setActiveTab] = useState<SettingsTabId>(readStoredSettingsTab);
  const [query, setQuery] = useState('');
  const [refreshBusy, setRefreshBusy] = useState(false);

  useLaneLoad(loadConfig);

  const onSelectTab = useCallback((tab: SettingsTabId) => {
    setActiveTab(tab);
    try {
      localStorage.setItem(SETTINGS_TAB_STORAGE_KEY, tab);
    } catch {
      /* ignore */
    }
  }, []);

  const onRefreshConfig = useCallback(() => {
    if (refreshBusy) return;
    setRefreshBusy(true);
    void loadConfig().finally(() => setRefreshBusy(false));
  }, [loadConfig, refreshBusy]);

  const onDone = useCallback(() => {
    setRoute('overview');
  }, [setRoute]);

  let body: ReactNode = null;

  if (loading && !config && !fixtureMode) {
    body = <SettingsSkeleton />;
  } else {
    body = (
      <div className="settings-split">
        <SettingsSidebar
          activeTab={activeTab}
          query={query}
          onQueryChange={setQuery}
          onSelectTab={onSelectTab}
        />
        <SettingsDetailPane
          activeTab={activeTab}
          config={config}
          fixtureMode={fixtureMode}
          bridge={bridge}
          status={status}
          loading={loading}
          error={error}
          onRetryConfig={() => void loadConfig()}
          onRefreshConfig={onRefreshConfig}
          refreshBusy={refreshBusy}
          onDone={onDone}
          onSelectTab={onSelectTab}
        />
      </div>
    );
  }

  return (
    <>
      <SystemStatusSection />
      <IntegrationsSection />
      {body}
    </>
  );
}
