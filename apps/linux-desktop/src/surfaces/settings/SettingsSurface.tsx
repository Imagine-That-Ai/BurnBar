import { useCallback, useEffect, useState } from 'react';
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
  settingsTabsMatchingQuery,
  type SettingsTabId
} from './settingsTabs.js';

export const SETTINGS_CONFIG_REQUEST_TIMEOUT_MS = 8_000;
export const SETTINGS_CONFIG_TIMEOUT_MESSAGE =
  'Settings config did not respond in time. Check the local daemon and retry.';

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

  // Settings is the recovery surface when the daemon is slow or restarting.
  // Start its first config request immediately; other lanes retain the
  // packaged idle-paint budget through the default loader behavior.
  useLaneLoad(loadConfig, { deferPackaged: false });

  useEffect(() => {
    if (fixtureMode || config || !loading) return;
    const timeout = window.setTimeout(() => {
      useSystemStore.setState((state) => {
        // A late daemon response may have completed normally while the timer
        // was queued. Never overwrite a valid snapshot or a newer error.
        if (state.config || !state.loading) return state;
        return {
          ...state,
          loading: false,
          error: SETTINGS_CONFIG_TIMEOUT_MESSAGE
        };
      });
    }, SETTINGS_CONFIG_REQUEST_TIMEOUT_MS);
    return () => window.clearTimeout(timeout);
  }, [config, fixtureMode, loading]);

  const onSelectTab = useCallback((tab: SettingsTabId) => {
    setActiveTab(tab);
    try {
      localStorage.setItem(SETTINGS_TAB_STORAGE_KEY, tab);
    } catch {
      /* ignore */
    }
  }, []);

  const onQueryChange = useCallback((value: string) => {
    setQuery(value);
    const normalizedQuery = value.trim();
    if (!normalizedQuery) return;

    const matches = settingsTabsMatchingQuery(normalizedQuery);
    if (matches.length === 0 || matches.some((tab) => tab.id === activeTab)) return;
    onSelectTab(matches[0]!.id);
  }, [activeTab, onSelectTab]);

  const onRefreshConfig = useCallback(() => {
    if (refreshBusy) return;
    setRefreshBusy(true);
    void loadConfig().finally(() => setRefreshBusy(false));
  }, [loadConfig, refreshBusy]);

  const onDone = useCallback(() => {
    setRoute('overview');
  }, [setRoute]);

  const onOpenDatabase = useCallback(() => {
    setRoute('database');
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
          onQueryChange={onQueryChange}
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
          onOpenDatabase={onOpenDatabase}
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
