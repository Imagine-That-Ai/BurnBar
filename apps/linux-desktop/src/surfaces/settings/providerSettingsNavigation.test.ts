// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { SETTINGS_TAB_STORAGE_KEY } from './settingsTabs.js';
import {
  navigateToProviderSettings,
  readProviderSettingsSelection,
  SETTINGS_PROVIDER_STORAGE_KEY,
  storeProviderSettingsSelection
} from './providerSettingsNavigation.js';

describe('provider settings navigation', () => {
  beforeEach(() => {
    localStorage.clear();
    useShellStore.setState({ route: 'providers' });
  });

  it('persists a valid provider selection and falls back when it disappears', () => {
    storeProviderSettingsSelection('anthropic');
    expect(readProviderSettingsSelection(['openai', 'anthropic'])).toBe('anthropic');
    expect(readProviderSettingsSelection(['openai'])).toBe('openai');
  });

  it('opens the Agents settings tab with the requested provider selected', () => {
    navigateToProviderSettings('openai');
    expect(useShellStore.getState().route).toBe('settings');
    expect(localStorage.getItem(SETTINGS_TAB_STORAGE_KEY)).toBe('agents');
    expect(localStorage.getItem(SETTINGS_PROVIDER_STORAGE_KEY)).toBe('openai');
  });
});
