export type InsightsCanvasLayout = 'balanced' | 'compact';

export type InsightsWorkspaceSnapshot = {
  version: 1;
  selectedWidgetID: string;
  layout: InsightsCanvasLayout;
};

const STORAGE_PREFIX = 'openburnbar.linux.insights.workspace.v1';
const DEFAULT_LAYOUT: InsightsCanvasLayout = 'balanced';

function hashScope(scope: string): string {
  // Keep account identifiers out of localStorage keys while retaining a
  // stable namespace per signed-in identity or installation device.
  let hash = 2166136261;
  for (const character of scope) {
    hash ^= character.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

export function insightsWorkspaceStorageKey(accountScope = 'local'): string {
  return `${STORAGE_PREFIX}.${hashScope(accountScope.trim() || 'local')}`;
}

export function accountScopeForInsights(status: {
  identityLabel?: string;
  installationDeviceID?: string;
} | null | undefined): string {
  // Prefer the account identity. A device ID is only the fallback when the
  // daemon is signed out or has not returned an account label yet.
  const stableIdentity = status?.identityLabel?.trim() || status?.installationDeviceID?.trim();
  return stableIdentity ? `account:${stableIdentity}` : 'local';
}

function normalizeLayout(value: unknown): InsightsCanvasLayout {
  return value === 'compact' ? 'compact' : DEFAULT_LAYOUT;
}

function safeStorage(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage;
  } catch {
    return null;
  }
}

export function readInsightsWorkspace(
  accountScope: string,
  availableWidgetIDs: readonly string[]
): InsightsWorkspaceSnapshot {
  const fallbackID = availableWidgetIDs[0] ?? 'usage-trend';
  const storage = safeStorage();
  if (!storage) {
    return { version: 1, selectedWidgetID: fallbackID, layout: DEFAULT_LAYOUT };
  }
  try {
    const raw = storage.getItem(insightsWorkspaceStorageKey(accountScope));
    if (!raw) return { version: 1, selectedWidgetID: fallbackID, layout: DEFAULT_LAYOUT };
    const parsed = JSON.parse(raw) as Partial<InsightsWorkspaceSnapshot>;
    const selectedWidgetID =
      typeof parsed.selectedWidgetID === 'string' && availableWidgetIDs.includes(parsed.selectedWidgetID)
        ? parsed.selectedWidgetID
        : fallbackID;
    return { version: 1, selectedWidgetID, layout: normalizeLayout(parsed.layout) };
  } catch {
    return { version: 1, selectedWidgetID: fallbackID, layout: DEFAULT_LAYOUT };
  }
}

export function writeInsightsWorkspace(accountScope: string, snapshot: InsightsWorkspaceSnapshot): void {
  const storage = safeStorage();
  if (!storage) return;
  try {
    storage.setItem(insightsWorkspaceStorageKey(accountScope), JSON.stringify(snapshot));
  } catch {
    // Persistence is best effort. The in-memory workspace remains usable.
  }
}
