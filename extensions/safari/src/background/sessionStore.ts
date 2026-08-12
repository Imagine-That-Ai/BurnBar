import type { BrowserAPI } from '../shared/browser';
import type { SafariMode } from '../shared/protocol';

const STORAGE_KEY = 'openburnbar.safari.preferences.v1';

export interface StoredSiteTrust {
  allowed: boolean;
  sensitiveOverride: boolean;
}

export interface SafariPreferences {
  selectedAgentId?: string;
  mode: SafariMode;
  onlyCurrentTab: boolean;
  learningOptedIn: boolean;
  learningConsentSeen: boolean;
  sites: Record<string, StoredSiteTrust>;
}

const DEFAULT_PREFERENCES: SafariPreferences = {
  mode: 'ask',
  onlyCurrentTab: true,
  learningOptedIn: false,
  learningConsentSeen: false,
  sites: {}
};

function isMode(value: unknown): value is SafariMode {
  return value === 'ask' || value === 'agentic' || value === 'watch' || value === 'handoff';
}

export function parsePreferences(value: unknown): SafariPreferences {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return { ...DEFAULT_PREFERENCES };
  }
  const record = value as Record<string, unknown>;
  const sites: Record<string, StoredSiteTrust> = {};
  if (record.sites && typeof record.sites === 'object' && !Array.isArray(record.sites)) {
    for (const [origin, candidate] of Object.entries(record.sites as Record<string, unknown>)) {
      if (
        candidate &&
        typeof candidate === 'object' &&
        !Array.isArray(candidate) &&
        typeof (candidate as Record<string, unknown>).allowed === 'boolean' &&
        typeof (candidate as Record<string, unknown>).sensitiveOverride === 'boolean'
      ) {
        sites[origin] = {
          allowed: (candidate as Record<string, unknown>).allowed as boolean,
          sensitiveOverride: (candidate as Record<string, unknown>).sensitiveOverride as boolean
        };
      }
    }
  }
  return {
    mode: isMode(record.mode) ? record.mode : DEFAULT_PREFERENCES.mode,
    onlyCurrentTab:
      typeof record.onlyCurrentTab === 'boolean' ? record.onlyCurrentTab : DEFAULT_PREFERENCES.onlyCurrentTab,
    learningOptedIn:
      typeof record.learningOptedIn === 'boolean' ? record.learningOptedIn : DEFAULT_PREFERENCES.learningOptedIn,
    learningConsentSeen:
      typeof record.learningConsentSeen === 'boolean'
        ? record.learningConsentSeen
        : DEFAULT_PREFERENCES.learningConsentSeen,
    sites,
    ...(typeof record.selectedAgentId === 'string' && record.selectedAgentId
      ? { selectedAgentId: record.selectedAgentId }
      : {})
  };
}

export class SafariSessionStore {
  constructor(private readonly browserAPI: BrowserAPI) {}

  async load(): Promise<SafariPreferences> {
    const values = await this.browserAPI.storage.local.get(STORAGE_KEY);
    return parsePreferences(values[STORAGE_KEY]);
  }

  async save(preferences: SafariPreferences): Promise<void> {
    await this.browserAPI.storage.local.set({
      [STORAGE_KEY]: preferences
    });
  }
}
