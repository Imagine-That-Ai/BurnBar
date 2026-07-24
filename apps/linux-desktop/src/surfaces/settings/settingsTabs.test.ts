import { describe, expect, it } from 'vitest';
import {
  SETTINGS_SECTIONS,
  SETTINGS_TABS,
  settingsTabMeta,
  settingsTabsMatchingQuery
} from './settingsTabs.js';

describe('Linux settings inventory', () => {
  it('exposes the complete 16-destination settings inventory', () => {
    expect(SETTINGS_TABS).toHaveLength(16);
    expect(SETTINGS_TABS.map((tab) => tab.id)).toEqual(expect.arrayContaining([
      'model-proxy',
      'computer-use',
      'pets'
    ]));
  });

  it('places the restored destinations in searchable sections with stable metadata', () => {
    expect(settingsTabMeta('model-proxy').section).toBe('agents-and-models');
    expect(settingsTabMeta('computer-use').section).toBe('extras');
    expect(settingsTabMeta('data-privacy').section).toBe('system');
    expect(settingsTabMeta('pets').section).toBe('extras');
    const sectionIDs = SETTINGS_SECTIONS.flatMap((section) => section.tabIds);
    expect(new Set(sectionIDs).size).toBe(SETTINGS_TABS.length - 1);
  });

  it('keeps section order aligned with the macOS settings oracle', () => {
    expect(SETTINGS_SECTIONS).toEqual([
      { id: 'agents-and-models', title: 'Agents & Models', tabIds: ['agents', 'model-proxy'] },
      { id: 'look-and-feel', title: 'Look & Feel', tabIds: ['general'] },
      {
        id: 'account-and-sync',
        title: 'Account & Sync',
        tabIds: ['account', 'cloud', 'devices-and-sync', 'alerts', 'notifications']
      },
      { id: 'system', title: 'System', tabIds: ['daemon', 'updates', 'data-privacy'] },
      { id: 'extras', title: 'More', tabIds: ['text-expansion', 'media', 'computer-use', 'pets'] }
    ]);
  });

  it('uses the same searchable fields for filtered navigation and detail selection', () => {
    expect(settingsTabsMatchingQuery('  MODEL PROXY ')).toEqual([
      settingsTabMeta('model-proxy')
    ]);
    expect(settingsTabsMatchingQuery('Secret Service').map((tab) => tab.id)).toEqual(['daemon']);
    expect(settingsTabsMatchingQuery('')).toHaveLength(SETTINGS_TABS.length);
    expect(settingsTabsMatchingQuery('does-not-exist')).toEqual([]);
  });
});
