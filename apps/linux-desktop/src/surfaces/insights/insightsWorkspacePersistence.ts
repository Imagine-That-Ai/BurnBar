export type InsightsCanvasLayout = 'balanced' | 'compact';

export type InsightsWorkspaceSnapshot = {
  version: 1;
  selectedWidgetID: string;
  layout: InsightsCanvasLayout;
};

const STORAGE_PREFIX = 'openburnbar.linux.insights.workspace.v1';
const STORAGE_VERSION = 1 as const;
const DEFAULT_LAYOUT: InsightsCanvasLayout = 'balanced';
const DEFAULT_WIDGET_ID = 'usage-trend';
const MAX_WIDGET_ID_LENGTH = 128;

type ReadStorage = Pick<Storage, 'getItem'>;
type WriteStorage = Pick<Storage, 'setItem'>;

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

function normalizedScope(accountScope: unknown): string {
  return typeof accountScope === 'string' && accountScope.trim() ? accountScope.trim() : 'local';
}

export function insightsWorkspaceStorageKey(accountScope?: string | null): string {
  return `${STORAGE_PREFIX}.${hashScope(normalizedScope(accountScope))}`;
}

export function accountScopeForInsights(status: {
  identityLabel?: string;
  installationDeviceID?: string;
} | null | undefined): string {
  // Prefer the account identity. A device ID is only the fallback when the
  // daemon is signed out or has not returned an account label yet.
  const identityLabel = typeof status?.identityLabel === 'string' ? status.identityLabel.trim() : '';
  const installationDeviceID =
    typeof status?.installationDeviceID === 'string' ? status.installationDeviceID.trim() : '';
  const stableIdentity = identityLabel || installationDeviceID;
  return stableIdentity ? `account:${stableIdentity}` : 'local';
}

function isInsightsCanvasLayout(value: unknown): value is InsightsCanvasLayout {
  return value === 'balanced' || value === 'compact';
}

function isSafeWidgetID(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= MAX_WIDGET_ID_LENGTH &&
    value === value.trim() &&
    ![...value].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)
  );
}

function defaultWorkspace(fallbackID: string): InsightsWorkspaceSnapshot {
  return { version: STORAGE_VERSION, selectedWidgetID: fallbackID, layout: DEFAULT_LAYOUT };
}

function safeStorage(): Storage | null {
  try {
    return typeof globalThis.localStorage === 'undefined' ? null : globalThis.localStorage;
  } catch {
    return null;
  }
}

function parseWorkspaceSnapshot(
  raw: string,
  fallback: InsightsWorkspaceSnapshot,
  availableWidgetIDs: readonly string[]
): InsightsWorkspaceSnapshot {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return fallback;
    const candidate = parsed as Record<string, unknown>;
    // Treat the record as all-or-nothing. Accepting a valid field from a
    // corrupt or future-version record can silently restore a state whose
    // semantics the renderer does not understand.
    if (
      candidate.version !== STORAGE_VERSION ||
      !isSafeWidgetID(candidate.selectedWidgetID) ||
      !availableWidgetIDs.includes(candidate.selectedWidgetID) ||
      !isInsightsCanvasLayout(candidate.layout)
    ) {
      return fallback;
    }
    return {
      version: STORAGE_VERSION,
      selectedWidgetID: candidate.selectedWidgetID,
      layout: candidate.layout
    };
  } catch {
    return fallback;
  }
}

function normalizeWritableSnapshot(snapshot: InsightsWorkspaceSnapshot): InsightsWorkspaceSnapshot | null {
  if (
    !snapshot ||
    snapshot.version !== STORAGE_VERSION ||
    !isSafeWidgetID(snapshot.selectedWidgetID) ||
    !isInsightsCanvasLayout(snapshot.layout)
  ) {
    return null;
  }
  return {
    version: STORAGE_VERSION,
    selectedWidgetID: snapshot.selectedWidgetID,
    layout: snapshot.layout
  };
}

export function readInsightsWorkspace(
  accountScope: string,
  availableWidgetIDs: readonly string[],
  storage: ReadStorage | null = safeStorage()
): InsightsWorkspaceSnapshot {
  const fallbackID = availableWidgetIDs[0] ?? DEFAULT_WIDGET_ID;
  if (!storage) return defaultWorkspace(fallbackID);
  try {
    const raw = storage.getItem(insightsWorkspaceStorageKey(accountScope));
    if (!raw) return defaultWorkspace(fallbackID);
    return parseWorkspaceSnapshot(raw, defaultWorkspace(fallbackID), availableWidgetIDs);
  } catch {
    return defaultWorkspace(fallbackID);
  }
}

export function writeInsightsWorkspace(
  accountScope: string,
  snapshot: InsightsWorkspaceSnapshot,
  storage: WriteStorage | null = safeStorage()
): void {
  const normalized = normalizeWritableSnapshot(snapshot);
  if (!storage || !normalized) return;
  try {
    storage.setItem(insightsWorkspaceStorageKey(accountScope), JSON.stringify(normalized));
  } catch {
    // Persistence is best effort. The in-memory workspace remains usable.
  }
}
