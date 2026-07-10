import { useShellStore } from '../../state/shellStore.js';
import { SETTINGS_TAB_STORAGE_KEY } from './settingsTabs.js';

export const SETTINGS_PROVIDER_STORAGE_KEY = 'openburnbar.linux.settings.provider.v1';

export function storeProviderSettingsSelection(providerID: string): void {
  try {
    localStorage.setItem(SETTINGS_PROVIDER_STORAGE_KEY, providerID);
  } catch {
    /* Settings navigation remains usable when storage is unavailable. */
  }
}

export function readProviderSettingsSelection(providerIDs: string[]): string {
  try {
    const stored = localStorage.getItem(SETTINGS_PROVIDER_STORAGE_KEY);
    if (stored && providerIDs.includes(stored)) return stored;
  } catch {
    /* Fall back to the first daemon provider. */
  }
  return providerIDs[0] ?? '';
}

export function navigateToProviderSettings(providerID: string): void {
  storeProviderSettingsSelection(providerID);
  try {
    localStorage.setItem(SETTINGS_TAB_STORAGE_KEY, 'agents');
  } catch {
    /* Settings still opens; Home remains the safe fallback tab. */
  }
  useShellStore.getState().setRoute('settings');
}
