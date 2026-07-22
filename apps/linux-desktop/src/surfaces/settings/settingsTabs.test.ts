import { describe, expect, it } from 'vitest';
import {
  SETTINGS_SECTIONS,
  SETTINGS_TABS,
  settingsTabMeta
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
    expect(settingsTabMeta('computer-use').section).toBe('system');
    expect(settingsTabMeta('pets').section).toBe('extras');
    const sectionIDs = SETTINGS_SECTIONS.flatMap((section) => section.tabIds);
    expect(new Set(sectionIDs).size).toBe(SETTINGS_TABS.length - 1);
  });
});
