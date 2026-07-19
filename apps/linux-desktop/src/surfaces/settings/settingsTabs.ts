export type SettingsTabId =
  | 'home'
  | 'general'
  | 'updates'
  | 'daemon'
  | 'account'
  | 'cloud'
  | 'agents'
  | 'model-proxy'
  | 'alerts'
  | 'notifications'
  | 'devices-and-sync'
  | 'text-expansion'
  | 'media'
  | 'data-privacy'
  | 'computer-use'
  | 'pets';

export type SettingsSectionId =
  | 'agents-and-models'
  | 'look-and-feel'
  | 'account-and-sync'
  | 'system'
  | 'extras';

export type SettingsTabMeta = {
  id: SettingsTabId;
  title: string;
  subtitle: string;
  iconGlyph: string;
  iconTint: string;
  section: SettingsSectionId | 'home';
  detailTitle: string;
};

export const SETTINGS_TAB_STORAGE_KEY = 'openburnbar.linux.settings.tab.v2';

export const SETTINGS_TABS: SettingsTabMeta[] = [
  {
    id: 'home',
    title: 'Home',
    subtitle: 'Health, attention items, and quick actions',
    iconGlyph: '⌂',
    iconTint: 'var(--color-brass-core)',
    section: 'home',
    detailTitle: 'Home'
  },
  {
    id: 'general',
    title: 'General',
    subtitle: 'Appearance, refresh, indexing, and setup',
    iconGlyph: '⚙',
    iconTint: 'var(--color-tier-server-readable)',
    section: 'look-and-feel',
    detailTitle: 'General'
  },
  {
    id: 'updates',
    title: 'Updates',
    subtitle: 'App version, package channel, restart guidance',
    iconGlyph: '↓',
    iconTint: 'var(--color-tier-end-to-end)',
    section: 'system',
    detailTitle: 'Updates'
  },
  {
    id: 'daemon',
    title: 'Engine Room',
    subtitle: 'Daemon lifecycle, socket paths, Secret Service',
    iconGlyph: '⎔',
    iconTint: 'var(--color-tier-end-to-end)',
    section: 'system',
    detailTitle: 'Daemon'
  },
  {
    id: 'account',
    title: 'Account',
    subtitle: 'Sign-in, subscription, and account actions',
    iconGlyph: '◎',
    iconTint: 'var(--color-brass-bright)',
    section: 'account-and-sync',
    detailTitle: 'Account'
  },
  {
    id: 'cloud',
    title: 'Cloud',
    subtitle: 'Hosted refresh, backup, and remote access',
    iconGlyph: '✦',
    iconTint: 'var(--color-brass-bright)',
    section: 'account-and-sync',
    detailTitle: 'OpenBurnBar Cloud'
  },
  {
    id: 'agents',
    title: 'Agents',
    subtitle: 'Cloud keys, local CLIs, and provider routing',
    iconGlyph: '◇',
    iconTint: 'var(--color-brass-core)',
    section: 'agents-and-models',
    detailTitle: 'Agents'
  },
  {
    id: 'model-proxy',
    title: 'Model Proxy',
    subtitle: 'Routing, failover, and local gateway health',
    iconGlyph: '⇄',
    iconTint: 'var(--color-brass-core)',
    section: 'agents-and-models',
    detailTitle: 'Model Proxy'
  },
  {
    id: 'alerts',
    title: 'Alerts',
    subtitle: 'Spend thresholds and daily digest',
    iconGlyph: '◉',
    iconTint: 'var(--color-seal-crimson)',
    section: 'account-and-sync',
    detailTitle: 'Alerts'
  },
  {
    id: 'notifications',
    title: 'Notifications',
    subtitle: 'Local pings and calendar hooks',
    iconGlyph: '◈',
    iconTint: 'var(--color-brass-bright)',
    section: 'account-and-sync',
    detailTitle: 'Notifications'
  },
  {
    id: 'devices-and-sync',
    title: 'Devices & Sync',
    subtitle: 'Cloud sync, trusted devices, smart displays',
    iconGlyph: '⊞',
    iconTint: 'var(--color-tier-end-to-end)',
    section: 'account-and-sync',
    detailTitle: 'Devices & Sync'
  },
  {
    id: 'text-expansion',
    title: 'Text Expansion',
    subtitle: '&& triggers, snippets, and in-app previews',
    iconGlyph: '¶',
    iconTint: 'var(--color-tier-server-readable)',
    section: 'extras',
    detailTitle: 'Text Expansion'
  },
  {
    id: 'media',
    title: 'Media & Sharing',
    subtitle: 'File transfer, screen share, and permissions',
    iconGlyph: '▣',
    iconTint: 'var(--color-tier-end-to-end)',
    section: 'extras',
    detailTitle: 'Media & Sharing'
  },
  {
    id: 'data-privacy',
    title: 'Data & Privacy',
    subtitle: 'Vault inventory, exports, telemetry, and consent',
    iconGlyph: '⛨',
    iconTint: 'var(--color-tier-end-to-end)',
    section: 'system',
    detailTitle: 'Data & Privacy'
  },
  {
    id: 'computer-use',
    title: 'Computer Use',
    subtitle: 'Browser automation, approvals, panic, and audit',
    iconGlyph: '⌁',
    iconTint: 'var(--color-seal-crimson)',
    section: 'extras',
    detailTitle: 'Computer Use'
  },
  {
    id: 'pets',
    title: 'Pets',
    subtitle: 'Companion overlay and compositor fallback',
    iconGlyph: '✧',
    iconTint: 'var(--color-brass-bright)',
    section: 'extras',
    detailTitle: 'Pets'
  }
];

export const SETTINGS_SECTIONS: { id: SettingsSectionId; title: string; tabIds: SettingsTabId[] }[] = [
  { id: 'agents-and-models', title: 'Agents & Models', tabIds: ['agents', 'model-proxy'] },
  { id: 'look-and-feel', title: 'Look & Feel', tabIds: ['general'] },
  {
    id: 'account-and-sync',
    title: 'Account & Sync',
    tabIds: ['account', 'cloud', 'devices-and-sync', 'alerts', 'notifications']
  },
  { id: 'system', title: 'System', tabIds: ['daemon', 'updates', 'data-privacy'] },
  { id: 'extras', title: 'More', tabIds: ['text-expansion', 'media', 'computer-use', 'pets'] }
];

/**
 * Return settings destinations that match the user-facing search contract.
 * Keep this shared by the sidebar and selection logic so a filtered result
 * never points at a different tab set than the detail pane.
 */
export function settingsTabsMatchingQuery(query: string): SettingsTabMeta[] {
  const normalizedQuery = query.trim().toLowerCase();
  if (!normalizedQuery) return SETTINGS_TABS;
  return SETTINGS_TABS.filter((tab) => {
    const haystack = `${tab.title} ${tab.subtitle} ${tab.detailTitle}`.toLowerCase();
    return haystack.includes(normalizedQuery);
  });
}

export function isSettingsTabId(value: string): value is SettingsTabId {
  return SETTINGS_TABS.some((t) => t.id === value);
}

export function settingsTabMeta(id: SettingsTabId): SettingsTabMeta {
  return SETTINGS_TABS.find((t) => t.id === id) ?? SETTINGS_TABS[0]!;
}

export function readStoredSettingsTab(): SettingsTabId {
  try {
    const raw = localStorage.getItem(SETTINGS_TAB_STORAGE_KEY);
    if (raw && isSettingsTabId(raw)) return raw;
    const legacy = localStorage.getItem('openburnbar.linux.settings.tab.v1');
    if (legacy === 'daemon') return 'daemon';
    if (legacy === 'agents') return 'agents';
    if (legacy === 'appearance') return 'general';
    if (legacy === 'privacy') return 'data-privacy';
    if (legacy === 'account') return 'account';
    if (legacy === 'paths') return 'daemon';
    if (legacy === 'advanced') return 'data-privacy';
  } catch {
    /* ignore */
  }
  return 'home';
}
