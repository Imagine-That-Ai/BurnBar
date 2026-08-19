import type { BrowserAPI } from '../shared/browser';
import type { SafariMode } from '../shared/protocol';

const STORAGE_KEY = 'openburnbar.safari.preferences.v1';

export interface StoredSiteTrust {
  allowed: boolean;
  sensitiveOverride: boolean;
}

// The cloud-screenshot disclosure is deliberately NOT part of this persisted
// shape. The enforcement error tells the user the acknowledgement applies "for
// this session", so it lives in controller memory and is cleared whenever the
// native session changes. Persisting it here would let one acknowledgement
// silently authorise cloud screenshots from every later Safari session.
export interface SafariPreferences {
  selectedAgentId?: string;
  mode: SafariMode;
  onlyCurrentTab: boolean;
  automaticallyTrustInvokedWebsites: boolean;
  learningOptedIn: boolean;
  learningConsentSeen: boolean;
  sites: Record<string, StoredSiteTrust>;
}

const DEFAULT_PREFERENCES: SafariPreferences = {
  mode: 'ask',
  onlyCurrentTab: true,
  automaticallyTrustInvokedWebsites: false,
  learningOptedIn: false,
  learningConsentSeen: false,
  sites: {}
};

function isMode(value: unknown): value is SafariMode {
  return value === 'ask' || value === 'agentic' || value === 'watch' || value === 'handoff';
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseStoredSiteTrust(value: unknown): StoredSiteTrust | undefined {
  if (!isRecord(value) || typeof value.allowed !== 'boolean' || typeof value.sensitiveOverride !== 'boolean') {
    return undefined;
  }
  return {
    allowed: value.allowed,
    sensitiveOverride: value.sensitiveOverride
  };
}

export function parsePreferences(value: unknown): SafariPreferences {
  if (!isRecord(value)) {
    return { ...DEFAULT_PREFERENCES };
  }
  const record = value;
  const sites: Record<string, StoredSiteTrust> = {};
  if (isRecord(record.sites)) {
    for (const [origin, candidate] of Object.entries(record.sites)) {
      const siteTrust = parseStoredSiteTrust(candidate);
      if (siteTrust) {
        sites[origin] = siteTrust;
      }
    }
  }
  return {
    mode: isMode(record.mode) ? record.mode : DEFAULT_PREFERENCES.mode,
    onlyCurrentTab:
      typeof record.onlyCurrentTab === 'boolean' ? record.onlyCurrentTab : DEFAULT_PREFERENCES.onlyCurrentTab,
    automaticallyTrustInvokedWebsites:
      typeof record.automaticallyTrustInvokedWebsites === 'boolean'
        ? record.automaticallyTrustInvokedWebsites
        : DEFAULT_PREFERENCES.automaticallyTrustInvokedWebsites,
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
