import { normalizeProxyRouteFinalStatus } from './proxyRouteContracts.js';
import {
  requireTimestamp
} from './tauriBridgeCoreDecoders.js';
import {
  mapConfigSnapshot
} from './tauriBridgeSystemDecoders.js';
import type {
  ConfigSnapshot,
  ProxyRouteLogEntry,
  NotificationConfig,
  NotificationHealth,
  NotificationCommandResult,
  NativeNotificationRoute,
  NativeNotificationCapabilities,
  NativeNotificationResult,
  NativeNotificationActionEvent,
  NativeShortcutStatus,
  NativeShortcutBindingStatus,
  DesktopWallpaperStatus,
  LinuxLaunchAtLoginStatus,
  PetCompanionStatus,
  PetAssetResponse,
  PetAtlasResponse,
  MercuryDevicePlatform,
  MercurySessionKind,
  MercurySessionState,
  MercuryCallPhase,
  MercuryPairedDevice,
  MercuryMediaStatus,
  MercuryMediaSessionState,
  MercuryMediaCapability,
  MercuryViewerCapabilityStatus,
  MercuryViewerCapability,
  MercuryFileTransferDirection,
  MercuryFileTransferPhase,
  MercuryFileTransferErrorCode,
  MercuryFileTransferProgress,
  MercuryFilePeer,
  MercuryFileTransfer,
  MercuryFileOfferListResponse,
  MercuryFileTransferActionResponse,
  ComputerUsePanicSource,
  ComputerUsePanicHaltResult,
  ComputerUseInvokeResponseStatus,
  ComputerUseInvokeResponse,
  TextExpansionMode,
  TextExpansionSurface,
  TextExpansionScope,
  TextExpansionWireSnippet,
  TextExpansionSnapshot,
  TextExpansionConsent,
  TextExpansionEngineRuntimeStatus,
  LinuxPrivacyStoreID,
  LinuxPrivacyStoreState,
  LinuxPrivacyStoreInventory,
  LinuxPrivacyInventory,
  LinuxPrivacyDeletionPreview,
  LinuxPrivacyDeletionResult,
  LinuxPrivacyExportResult,
  LinuxPrivacyRetentionPolicyState,
  LinuxPrivacyRetentionRule,
  LinuxPrivacyRetentionStoreStatus,
  LinuxPrivacyRetentionStatus,
  LinuxPrivacyRetentionApplyResult
} from './tauriBridgeTypes.js';
import type { RawJsonValue } from './tauriBridgeRaw.js';
import {
  num,
  str,
  arr,
  obj,
  pick,
  requireObject,
  requireString,
  requireBoolean
} from './tauriBridgeRaw.js';

export const TEXT_EXPANSION_SURFACES = new Set<TextExpansionSurface>([
  'in_app_thread',
  'mac_global',
  'ios_keyboard',
  'android_ime'
]);

export function mapTextExpansionScope(raw: RawJsonValue): TextExpansionScope {
  const scope = obj(raw);
  const surfaces = arr(pick(scope, 'surfaces'))
    .map((value) => str(value))
    .filter((value): value is TextExpansionSurface => TEXT_EXPANSION_SURFACES.has(value as TextExpansionSurface));
  return {
    surfaces,
    bundleIdentifiers: arr(pick(scope, 'bundleIdentifiers', 'bundle_identifiers')).map((value) => str(value)).filter(Boolean),
    threadIDs: arr(pick(scope, 'threadIDs', 'thread_ids')).map((value) => str(value)).filter(Boolean)
  };
}

export function mapTextExpansionSnippet(raw: RawJsonValue): TextExpansionWireSnippet {
  const value = obj(raw);
  const mode = str(pick(value, 'mode'), 'static');
  if (!['static', 'llm_rewrite'].includes(mode)) {
    throw new Error('Native text expansion returned an unsupported mode.');
  }
  const id = str(pick(value, 'id'));
  const title = str(pick(value, 'title'));
  const trigger = str(pick(value, 'trigger'));
  const body = str(pick(value, 'body'));
  const createdAt = str(pick(value, 'createdAt', 'created_at'));
  const updatedAt = str(pick(value, 'updatedAt', 'updated_at'));
  const scope = mapTextExpansionScope(pick(value, 'scope'));
  if (!id || !title || !trigger || !createdAt || !updatedAt || scope.surfaces.length !== 1 || scope.surfaces[0] !== 'in_app_thread') {
    throw new Error('Native text expansion returned an invalid snippet.');
  }
  return {
    id,
    title,
    trigger,
    body,
    mode: mode as TextExpansionMode,
    isEnabled: Boolean(pick(value, 'isEnabled', 'is_enabled')),
    scope: { surfaces: ['in_app_thread'], bundleIdentifiers: [], threadIDs: [] },
    revision: Math.max(1, Math.trunc(num(pick(value, 'revision'), 1))),
    createdAt,
    updatedAt,
    deletedAt: str(pick(value, 'deletedAt', 'deleted_at')) || null,
    syncedAt: str(pick(value, 'syncedAt', 'synced_at')) || null,
    sourceDeviceID: str(pick(value, 'sourceDeviceID', 'source_device_id')) || null
  };
}

export function mapTextExpansionSnapshot(raw: RawJsonValue): TextExpansionSnapshot {
  const value = obj(pick(raw, 'snapshot') ?? raw);
  const schemaVersion = Math.trunc(num(pick(value, 'schemaVersion', 'schema_version')));
  if (schemaVersion !== 1) {
    throw new Error('Native text expansion returned an unsupported schema.');
  }
  const snippets = arr(pick(value, 'snippets')).map(mapTextExpansionSnippet);
  const rawConsent = pick(value, 'consent');
  const consentValue = rawConsent === undefined || rawConsent === null ? null : obj(rawConsent);
  const consent = consentValue
    ? {
        inAppOnly: Boolean(pick(consentValue, 'inAppOnly', 'in_app_only')),
        acknowledgedAt: requireTimestamp(pick(consentValue, 'acknowledgedAt', 'acknowledged_at'), 'text expansion consent.acknowledgedAt'),
        declinedGlobalCapture: Boolean(pick(consentValue, 'declinedGlobalCapture', 'declined_global_capture')),
        systemIMEEnabled: Boolean(pick(consentValue, 'systemIMEEnabled', 'system_ime_enabled'))
      }
    : null;
  const rawNativeStatus = pick(value, 'nativeStatus', 'native_status');
  const nativeStatusValue = rawNativeStatus === undefined || rawNativeStatus === null ? null : obj(rawNativeStatus);
  const nativeStatus = nativeStatusValue
    ? {
        status: str(pick(nativeStatusValue, 'status'), 'blocked'),
        backend: str(pick(nativeStatusValue, 'backend')) || null,
        backendPath: str(pick(nativeStatusValue, 'backendPath', 'backend_path')) || null,
        sessionType: str(pick(nativeStatusValue, 'sessionType', 'session_type'), 'unknown'),
        registration: str(pick(nativeStatusValue, 'registration'), 'engine_not_registered'),
        supportsExternalExpansion: Boolean(pick(nativeStatusValue, 'supportsExternalExpansion', 'supports_external_expansion')),
        secureFieldPolicy: str(
          pick(nativeStatusValue, 'secureFieldPolicy', 'secure_field_policy'),
          'deny-unless-inspectable-and-explicitly-nonsecure'
        ),
        noGlobalCapture: pick(nativeStatusValue, 'noGlobalCapture', 'no_global_capture') !== false,
        detail: str(pick(nativeStatusValue, 'detail'), 'Native text expansion status is unavailable.'),
        checkedAt: str(pick(nativeStatusValue, 'checkedAt', 'checked_at'), new Date().toISOString())
      }
    : null;
  return {
    schemaVersion,
    exportedAt: str(pick(value, 'exportedAt', 'exported_at'), new Date().toISOString()),
    snippets,
    consent,
    nativeStatus
  };
}

export function mapTextExpansionConsent(raw: RawJsonValue): TextExpansionConsent {
  const value = obj(pick(raw, 'consent') ?? raw);
  return {
    inAppOnly: Boolean(pick(value, 'inAppOnly', 'in_app_only')),
    acknowledgedAt: requireTimestamp(pick(value, 'acknowledgedAt', 'acknowledged_at'), 'text expansion consent.acknowledgedAt'),
    declinedGlobalCapture: Boolean(pick(value, 'declinedGlobalCapture', 'declined_global_capture')),
    systemIMEEnabled: Boolean(pick(value, 'systemIMEEnabled', 'system_ime_enabled'))
  };
}

export function mapTextExpansionEngineRuntimeStatus(raw: RawJsonValue): TextExpansionEngineRuntimeStatus {
  const value = obj(pick(raw, 'result') ?? raw);
  return {
    state: str(pick(value, 'state'), 'not_running'),
    engineID: str(pick(value, 'engineID', 'engine_id')) || null,
    executablePath: str(pick(value, 'executablePath', 'executable_path')) || null,
    registration: str(pick(value, 'registration'), 'engine_missing'),
    supportsExternalExpansion: Boolean(pick(value, 'supportsExternalExpansion', 'supports_external_expansion')),
    detail: str(pick(value, 'detail'), 'Text expansion engine status is unavailable.'),
    checkedAt: str(pick(value, 'checkedAt', 'checked_at'), new Date().toISOString())
  };
}

export function snapshotFromMutation(raw: RawJsonValue): ConfigSnapshot {
  return mapConfigSnapshot(pick(raw, 'snapshot') ? raw : { snapshot: pick(raw, 'snapshot') ?? raw });
}

export function mapProxyRouteLog(raw: RawJsonValue): ProxyRouteLogEntry[] {
  return arr(pick(raw, 'entries')).map((entry, i): ProxyRouteLogEntry => ({
    id: str(pick(entry, 'id'), `route-log-${i}`),
    occurredAt: str(pick(entry, 'occurredAt'), new Date().toISOString()),
    endpoint: str(pick(entry, 'endpoint')),
    clientModelSlug: str(pick(entry, 'clientModelSlug')),
    routingModelSlug: str(pick(entry, 'routingModelSlug')) || undefined,
    upstreamModelSlug: str(pick(entry, 'upstreamModelSlug')) || undefined,
    providerName: str(pick(entry, 'providerName')) || undefined,
    accountLabel: str(pick(entry, 'accountLabel')) || undefined,
    finalStatus: normalizeProxyRouteFinalStatus(str(pick(entry, 'finalStatus'), 'unknown')),
    rewriteKind: str(pick(entry, 'rewriteKind'), 'none'),
    exactModelInvariant: str(pick(entry, 'exactModelInvariant'), 'not_applicable'),
    streamed: Boolean(pick(entry, 'streamed')),
    streamInterrupted: Boolean(pick(entry, 'streamInterrupted')),
    httpStatus: pick(entry, 'httpStatus') == null ? undefined : num(pick(entry, 'httpStatus')),
    failureMessage: str(pick(entry, 'failureMessage')) || undefined
  }));
}

export const LINUX_PRIVACY_STORES = new Set<LinuxPrivacyStoreID>(['proxy_route_log', 'text_expansion_store']);
export const LINUX_PRIVACY_STATES = new Set<LinuxPrivacyStoreState>(['absent', 'ready', 'blocked']);
export const LINUX_PRIVACY_RETENTION_STATES = new Set<LinuxPrivacyRetentionPolicyState>(['defaults', 'configured', 'blocked']);
export const LINUX_PRIVACY_RETENTION_MIN_AGE_SECONDS = 60 * 60;
export const LINUX_PRIVACY_RETENTION_MAX_AGE_SECONDS = 365 * 24 * 60 * 60;
export const LINUX_PRIVACY_RETENTION_MIN_BYTES = 64 * 1024;
export const LINUX_PRIVACY_RETENTION_MAX_BYTES = 64 * 1024 * 1024;

export function mapLinuxPrivacyStoreInventory(raw: RawJsonValue): LinuxPrivacyStoreInventory {
  const value = obj(raw);
  const store = str(pick(value, 'store')) as LinuxPrivacyStoreID;
  const state = str(pick(value, 'state')) as LinuxPrivacyStoreState;
  if (!LINUX_PRIVACY_STORES.has(store) || !LINUX_PRIVACY_STATES.has(state)) {
    throw new Error('Native privacy inventory returned an unsupported store.');
  }
  return {
    store,
    state,
    bytes: Math.max(0, Math.trunc(num(pick(value, 'bytes')))),
    reason: str(pick(value, 'reason'), 'unavailable')
  };
}

export function mapLinuxPrivacyInventory(raw: RawJsonValue): LinuxPrivacyInventory {
  const value = obj(pick(raw, 'result') ?? raw);
  return {
    stores: arr(pick(value, 'stores')).map(mapLinuxPrivacyStoreInventory),
    generatedAt: requireTimestamp(pick(value, 'generatedAt', 'generated_at'), 'privacy inventory.generatedAt')
  };
}

export function mapLinuxPrivacyDeletionPreview(raw: RawJsonValue): LinuxPrivacyDeletionPreview {
  const value = obj(pick(raw, 'result') ?? raw);
  const stores = arr(pick(value, 'stores')).map((item) => {
    const store = str(item) as LinuxPrivacyStoreID;
    if (!LINUX_PRIVACY_STORES.has(store)) throw new Error('Native privacy preview returned an unsupported store.');
    return store;
  });
  return {
    token: requireString(pick(value, 'token'), 'privacy deletion preview.token'),
    stores,
    entries: arr(pick(value, 'entries')).map(mapLinuxPrivacyStoreInventory),
    expiresAt: requireTimestamp(pick(value, 'expiresAt', 'expires_at'), 'privacy deletion preview.expiresAt'),
    confirmationPhrase: requireString(
      pick(value, 'confirmationPhrase', 'confirmation_phrase'),
      'privacy deletion preview.confirmationPhrase'
    )
  };
}

export function mapLinuxPrivacyDeletionResult(raw: RawJsonValue): LinuxPrivacyDeletionResult {
  const value = obj(pick(raw, 'result') ?? raw);
  const stores = (key: string): LinuxPrivacyStoreID[] => arr(pick(value, key)).map((item) => {
    const store = str(item) as LinuxPrivacyStoreID;
    if (!LINUX_PRIVACY_STORES.has(store)) throw new Error('Native privacy deletion returned an unsupported store.');
    return store;
  });
  return {
    stores: stores('stores'),
    deleted: stores('deleted'),
    alreadyAbsent: stores('alreadyAbsent'),
    bytesRemoved: Math.max(0, Math.trunc(num(pick(value, 'bytesRemoved', 'bytes_removed')))),
    idempotent: Boolean(pick(value, 'idempotent'))
  };
}

export function mapLinuxPrivacyExport(raw: RawJsonValue): LinuxPrivacyExportResult {
  const value = obj(pick(raw, 'result') ?? raw);
  const stores = arr(pick(value, 'stores')).map((item) => {
    const store = str(item) as LinuxPrivacyStoreID;
    if (!LINUX_PRIVACY_STORES.has(store)) throw new Error('Native privacy export returned an unsupported store.');
    return store;
  });
  const byteCount = Math.trunc(num(pick(value, 'byteCount', 'byte_count')));
  const formatVersion = Math.trunc(num(pick(value, 'formatVersion', 'format_version')));
  if (byteCount < 0 || formatVersion < 1) throw new Error('Native privacy export returned invalid metadata.');
  return {
    stores,
    destinationPath: requireString(pick(value, 'destinationPath', 'destination_path'), 'privacy export.destinationPath'),
    byteCount,
    formatVersion
  };
}

export function mapLinuxPrivacyRetentionRule(raw: RawJsonValue): LinuxPrivacyRetentionRule {
  const value = obj(raw);
  const store = str(pick(value, 'store')) as LinuxPrivacyStoreID;
  const maxAgeSeconds = Math.trunc(num(pick(value, 'maxAgeSeconds', 'max_age_seconds')));
  const maxBytes = Math.trunc(num(pick(value, 'maxBytes', 'max_bytes')));
  if (
    !LINUX_PRIVACY_STORES.has(store) ||
    maxAgeSeconds < LINUX_PRIVACY_RETENTION_MIN_AGE_SECONDS ||
    maxAgeSeconds > LINUX_PRIVACY_RETENTION_MAX_AGE_SECONDS ||
    maxBytes < LINUX_PRIVACY_RETENTION_MIN_BYTES ||
    maxBytes > LINUX_PRIVACY_RETENTION_MAX_BYTES
  ) {
    throw new Error('Native privacy retention returned an invalid rule.');
  }
  return { store, maxAgeSeconds, maxBytes };
}

export function mapLinuxPrivacyRetentionStoreStatus(raw: RawJsonValue): LinuxPrivacyRetentionStoreStatus {
  const value = obj(raw);
  const store = str(pick(value, 'store')) as LinuxPrivacyStoreID;
  const state = str(pick(value, 'state')) as LinuxPrivacyStoreState;
  const bytes = Math.trunc(num(pick(value, 'bytes')));
  const maxAgeSeconds = Math.trunc(num(pick(value, 'maxAgeSeconds', 'max_age_seconds')));
  const maxBytes = Math.trunc(num(pick(value, 'maxBytes', 'max_bytes')));
  const rawAge = pick(value, 'ageSeconds', 'age_seconds');
  const ageSeconds = rawAge == null ? undefined : Math.max(0, Math.trunc(num(rawAge)));
  if (
    !LINUX_PRIVACY_STORES.has(store) ||
    !LINUX_PRIVACY_STATES.has(state) ||
    bytes < 0 ||
    maxAgeSeconds < LINUX_PRIVACY_RETENTION_MIN_AGE_SECONDS ||
    maxAgeSeconds > LINUX_PRIVACY_RETENTION_MAX_AGE_SECONDS ||
    maxBytes < LINUX_PRIVACY_RETENTION_MIN_BYTES ||
    maxBytes > LINUX_PRIVACY_RETENTION_MAX_BYTES
  ) {
    throw new Error('Native privacy retention returned invalid store status.');
  }
  return {
    store,
    state,
    bytes,
    ageSeconds,
    maxAgeSeconds,
    maxBytes,
    wouldPurge: Boolean(pick(value, 'wouldPurge', 'would_purge')),
    reason: str(pick(value, 'reason'), 'unavailable')
  };
}

export function mapLinuxPrivacyRetentionStatus(raw: RawJsonValue): LinuxPrivacyRetentionStatus {
  const value = obj(pick(raw, 'result') ?? raw);
  const policyState = str(pick(value, 'policyState', 'policy_state')) as LinuxPrivacyRetentionPolicyState;
  const rules = arr(pick(value, 'rules')).map(mapLinuxPrivacyRetentionRule);
  const stores = arr(pick(value, 'stores')).map(mapLinuxPrivacyRetentionStoreStatus);
  if (!LINUX_PRIVACY_RETENTION_STATES.has(policyState)) {
    throw new Error('Native privacy retention returned an unsupported policy state.');
  }
  if (
    rules.length !== LINUX_PRIVACY_STORES.size ||
    stores.length !== LINUX_PRIVACY_STORES.size ||
    new Set(rules.map((rule) => rule.store)).size !== LINUX_PRIVACY_STORES.size ||
    new Set(stores.map((store) => store.store)).size !== LINUX_PRIVACY_STORES.size
  ) {
    throw new Error('Native privacy retention returned an incomplete store set.');
  }
  return {
    policyState,
    rules,
    stores,
    evaluatedAt: requireTimestamp(pick(value, 'evaluatedAt', 'evaluated_at'), 'privacy retention.evaluatedAt')
  };
}

export function mapLinuxPrivacyRetentionApply(raw: RawJsonValue): LinuxPrivacyRetentionApplyResult {
  const value = obj(pick(raw, 'result') ?? raw);
  const removedBytes = Math.trunc(num(pick(value, 'removedBytes', 'removed_bytes')));
  const removedEntries = Math.trunc(num(pick(value, 'removedEntries', 'removed_entries')));
  if (removedBytes < 0 || removedEntries < 0) {
    throw new Error('Native privacy retention returned invalid removal metadata.');
  }
  return {
    status: mapLinuxPrivacyRetentionStatus(pick(value, 'status')),
    removedBytes,
    removedEntries
  };
}

export function defaultNotificationConfig(): NotificationConfig {
  return {
    defaultSnoozeMinutes: 30,
    nudgeHoursLocal: [9, 13, 17],
    local: { isEnabled: true, quietHoursStart: null, quietHoursEnd: null },
    telegram: {
      isEnabled: false,
      botTokenConfigured: false,
      botToken: null,
      botTokenHint: null,
      chatID: null,
      supportedCommands: ['help', 'pending', 'followups', 'latest', 'status']
    },
    calendar: { isEnabled: false, defaultDurationMinutes: 30, defaultCalendarName: null }
  };
}

const NOTIFICATION_SNOOZE_MINUTES = { min: 1, max: 1_440 } as const;
const NOTIFICATION_NUDGE_HOURS = { min: 0, max: 23 } as const;
const NOTIFICATION_CALENDAR_DURATIONS = new Set([15, 30, 45, 60, 90]);

function optionalBooleanWithDefault(value: RawJsonValue, fallback: boolean): boolean {
  return value === undefined || value === null ? fallback : Boolean(value);
}

function boundedInteger(value: RawJsonValue, fallback: number, min: number, max: number): number {
  const parsed = num(value, Number.NaN);
  return Number.isSafeInteger(parsed) && parsed >= min && parsed <= max ? parsed : fallback;
}

function optionalHour(value: RawJsonValue): number | null {
  if (value === undefined || value === null) return null;
  const parsed = num(value, Number.NaN);
  return Number.isSafeInteger(parsed)
    && parsed >= NOTIFICATION_NUDGE_HOURS.min
    && parsed <= NOTIFICATION_NUDGE_HOURS.max
    ? parsed
    : null;
}

export function mapNotificationConfig(raw: RawJsonValue): NotificationConfig {
  const c = pick(raw, 'config') ?? raw;
  const fallback = defaultNotificationConfig();
  const local = pick(c, 'local');
  const telegram = pick(c, 'telegram');
  const calendar = pick(c, 'calendar');
  const nudgeHoursLocal = Array.from(new Set(
    arr(pick(c, 'nudgeHoursLocal'))
      .map((value) => optionalHour(value))
      .filter((value): value is number => value !== null)
  ));
  return {
    defaultSnoozeMinutes: boundedInteger(
      pick(c, 'defaultSnoozeMinutes'),
      fallback.defaultSnoozeMinutes,
      NOTIFICATION_SNOOZE_MINUTES.min,
      NOTIFICATION_SNOOZE_MINUTES.max
    ),
    nudgeHoursLocal: nudgeHoursLocal.length > 0 ? nudgeHoursLocal : fallback.nudgeHoursLocal,
    local: {
      isEnabled: optionalBooleanWithDefault(pick(local, 'isEnabled'), fallback.local.isEnabled),
      quietHoursStart: optionalHour(pick(local, 'quietHoursStart')),
      quietHoursEnd: optionalHour(pick(local, 'quietHoursEnd'))
    },
    telegram: {
      isEnabled: optionalBooleanWithDefault(pick(telegram, 'isEnabled'), fallback.telegram.isEnabled),
      botTokenConfigured: optionalBooleanWithDefault(pick(telegram, 'botTokenConfigured'), fallback.telegram.botTokenConfigured),
      botToken: str(pick(telegram, 'botToken')) || null,
      botTokenHint: str(pick(telegram, 'botTokenHint')) || null,
      chatID: str(pick(telegram, 'chatID', 'chatId')) || null,
      supportedCommands: arr(pick(telegram, 'supportedCommands')).map((v) => str(v)).filter(Boolean).length > 0
        ? arr(pick(telegram, 'supportedCommands')).map((v) => str(v)).filter(Boolean)
        : fallback.telegram.supportedCommands
    },
    calendar: {
      isEnabled: optionalBooleanWithDefault(pick(calendar, 'isEnabled'), fallback.calendar.isEnabled),
      defaultDurationMinutes: (() => {
        const parsed = num(pick(calendar, 'defaultDurationMinutes'), Number.NaN);
        return Number.isSafeInteger(parsed) && NOTIFICATION_CALENDAR_DURATIONS.has(parsed)
          ? parsed
          : fallback.calendar.defaultDurationMinutes;
      })(),
      defaultCalendarName: str(pick(calendar, 'defaultCalendarName')) || null
    }
  };
}

export function mapNotificationHealth(raw: RawJsonValue): NotificationHealth {
  const h = pick(raw, 'health') ?? raw;
  return {
    checkedAt: str(pick(h, 'checkedAt'), new Date().toISOString()),
    channels: arr(pick(h, 'channels')).map((channel) => ({
      channel: str(pick(channel, 'channel'), 'local') as 'local' | 'telegram' | 'calendar',
      status: str(pick(channel, 'status'), 'disabled'),
      detail: str(pick(channel, 'detail')) || null,
      checkedAt: str(pick(channel, 'checkedAt'), new Date().toISOString())
    }))
  };
}

export function mapNotificationCommand(raw: RawJsonValue): NotificationCommandResult {
  return {
    command: str(pick(raw, 'command'), 'status'),
    ok: Boolean(pick(raw, 'ok')),
    message: str(pick(raw, 'message'), 'Command finished.')
  };
}

export const NATIVE_NOTIFICATION_ROUTES: readonly NativeNotificationRoute[] = [
  'overview', 'chat', 'insights', 'settings', 'activity', 'account', 'updates', 'support'
];

export function decodeNativeNotificationCapabilities(raw: RawJsonValue): NativeNotificationCapabilities {
  const value = requireObject(raw, 'native notification capabilities');
  const serverCapabilities = arr(pick(value, 'serverCapabilities', 'server_capabilities'))
    .map((entry) => requireString(entry, 'native notification capability'));
  const degradedReason = str(pick(value, 'degradedReason', 'degraded_reason')) || undefined;
  return {
    available: requireBoolean(pick(value, 'available'), 'native notification availability'),
    actions: requireBoolean(pick(value, 'actions'), 'native notification actions capability'),
    persistence: requireBoolean(pick(value, 'persistence'), 'native notification persistence capability'),
    body: requireBoolean(pick(value, 'body'), 'native notification body capability'),
    bodyMarkup: requireBoolean(pick(value, 'bodyMarkup', 'body_markup'), 'native notification body-markup capability'),
    serverCapabilities,
    degradedReason
  };
}

export function decodeNativeNotificationResult(raw: RawJsonValue): NativeNotificationResult {
  const value = requireObject(raw, 'native notification result');
  return {
    notificationId: requireString(pick(value, 'notificationId', 'notification_id'), 'native notification id'),
    delivered: requireBoolean(pick(value, 'delivered'), 'native notification delivery'),
    actionsAttached: requireBoolean(pick(value, 'actionsAttached', 'actions_attached'), 'native notification actions attached'),
    degradedReason: str(pick(value, 'degradedReason', 'degraded_reason')) || undefined
  };
}

export function decodeNativeNotificationActionEvent(raw: RawJsonValue): NativeNotificationActionEvent {
  const value = requireObject(raw, 'native notification action');
  const route = requireString(pick(value, 'route'), 'native notification action route');
  if (!NATIVE_NOTIFICATION_ROUTES.includes(route as NativeNotificationRoute)) {
    throw new Error(`native notification action route is unsupported: ${route}`);
  }
  const action = requireString(pick(value, 'action'), 'native notification action id');
  if (action !== 'open' && action !== 'reply') {
    throw new Error(`native notification action id is unsupported: ${action}`);
  }
  const rawPayload = pick(value, 'payload');
  const payload = rawPayload === undefined
    ? undefined
    : requireObject(rawPayload, 'native notification action payload');
  return {
    notificationId: requireString(pick(value, 'notificationId', 'notification_id'), 'native notification action notificationId'),
    route: route as NativeNotificationRoute,
    action: action as 'open' | 'reply',
    ...(payload ? { payload } : {})
  };
}

export function decodeNativeNotificationActionEvents(raw: RawJsonValue): NativeNotificationActionEvent[] {
  if (!Array.isArray(raw)) throw new Error('native notification action queue must be an array.');
  return raw.map((event) => decodeNativeNotificationActionEvent(event));
}

export function decodeNativeShortcutStatus(raw: RawJsonValue): NativeShortcutStatus {
  const value = requireObject(raw, 'native shortcut status');
  const backend = str(pick(value, 'backend'));
  if (backend && backend !== 'x11' && backend !== 'wayland' && backend !== 'unknown') {
    throw new Error(`native shortcut backend is unsupported: ${backend}`);
  }
  const rawBindings = pick(value, 'bindings');
  const bindings = rawBindings === undefined
    ? undefined
    : arr(rawBindings).map((rawBinding) => {
      const binding = requireObject(rawBinding, 'native shortcut binding');
      const state = requireString(pick(binding, 'state'), 'native shortcut binding state');
      if (state !== 'registered' && state !== 'degraded' && state !== 'unavailable') {
        throw new Error(`native shortcut binding state is unsupported: ${state}`);
      }
      return {
        id: requireString(pick(binding, 'id'), 'native shortcut binding id'),
        shortcut: requireString(pick(binding, 'shortcut'), 'native shortcut binding shortcut'),
        state,
        degradedReason: str(pick(binding, 'degradedReason', 'degraded_reason')) || undefined
      } satisfies NativeShortcutBindingStatus;
    });
  return {
    available: requireBoolean(pick(value, 'available'), 'native shortcut availability'),
    registered: requireBoolean(pick(value, 'registered'), 'native shortcut registration'),
    shortcuts: arr(pick(value, 'shortcuts')).map((shortcut) => requireString(shortcut, 'native shortcut')),
    ...(backend ? { backend: backend as NativeShortcutStatus['backend'] } : {}),
    ...(bindings ? { bindings } : {}),
    ...(pick(value, 'portalAvailable', 'portal_available') === undefined
      ? {}
      : { portalAvailable: requireBoolean(pick(value, 'portalAvailable', 'portal_available'), 'native shortcut portal availability') }),
    ...(str(pick(value, 'portalReason', 'portal_reason'))
      ? { portalReason: str(pick(value, 'portalReason', 'portal_reason')) }
      : {}),
    degradedReason: str(pick(value, 'degradedReason', 'degraded_reason')) || undefined
  };
}

export function decodeDesktopWallpaperStatus(raw: RawJsonValue): DesktopWallpaperStatus {
  const value = requireObject(raw, 'desktop wallpaper status');
  const backend = requireString(pick(value, 'backend'), 'desktop wallpaper backend');
  if (backend !== 'gnome' && backend !== 'kde' && backend !== 'xfce' && backend !== 'sway' && backend !== 'hyprland' && backend !== 'unsupported') {
    throw new Error(`desktop wallpaper backend is unsupported: ${backend}`);
  }
  const state = requireString(pick(value, 'state'), 'desktop wallpaper state');
  if (state !== 'ready' && state !== 'applied' && state !== 'restored' && state !== 'degraded' && state !== 'unsupported') {
    throw new Error(`desktop wallpaper state is unsupported: ${state}`);
  }
  return {
    available: requireBoolean(pick(value, 'available'), 'desktop wallpaper availability'),
    backend: backend as DesktopWallpaperStatus['backend'],
    state: state as DesktopWallpaperStatus['state'],
    restoreAvailable: pick(value, 'restoreAvailable', 'restore_available') === undefined
      ? false
      : requireBoolean(pick(value, 'restoreAvailable', 'restore_available'), 'desktop wallpaper restore availability'),
    ...(str(pick(value, 'theme')) ? { theme: str(pick(value, 'theme')) } : {}),
    ...(str(pick(value, 'path')) ? { path: str(pick(value, 'path')) } : {}),
    ...(str(pick(value, 'reason')) ? { reason: str(pick(value, 'reason')) } : {})
  };
}

export function decodeLaunchAtLoginStatus(raw: RawJsonValue): LinuxLaunchAtLoginStatus {
  const value = requireObject(raw, 'launch-at-login status');
  const source = requireString(pick(value, 'source'), 'launch-at-login source');
  if (source !== 'user' && source !== 'packaged' && source !== 'unavailable') {
    throw new Error(`launch-at-login source is unsupported: ${source}`);
  }
  return {
    enabled: requireBoolean(pick(value, 'enabled'), 'launch-at-login enabled state'),
    userOverride: requireBoolean(pick(value, 'userOverride', 'user_override'), 'launch-at-login user override'),
    source: source as LinuxLaunchAtLoginStatus['source'],
    path: requireString(pick(value, 'path'), 'launch-at-login path'),
    ...(str(pick(value, 'detail')) ? { detail: str(pick(value, 'detail')) } : {})
  };
}

export function decodePetCompanionStatus(raw: RawJsonValue): PetCompanionStatus {
  const value = requireObject(raw, 'pet companion status');
  const state = requireString(pick(value, 'state'), 'pet companion state');
  if (state !== 'available' && state !== 'degraded' && state !== 'unavailable') {
    throw new Error(`pet companion state is unsupported: ${state}`);
  }
  return {
    state,
    compositor: requireString(pick(value, 'compositor'), 'pet companion compositor'),
    sessionType: str(pick(value, 'sessionType', 'session_type')) || undefined,
    desktop: str(pick(value, 'desktop')) || undefined,
    overlaySupported: requireBoolean(
      pick(value, 'overlaySupported', 'overlay_supported'),
      'pet companion overlay capability'
    ),
    clickThroughSupported: requireBoolean(
      pick(value, 'clickThroughSupported', 'click_through_supported'),
      'pet companion click-through capability'
    ),
    windowContract: requireString(pick(value, 'windowContract', 'window_contract'), 'pet companion window contract'),
    reason: requireString(pick(value, 'reason'), 'pet companion reason'),
    source: requireString(pick(value, 'source'), 'pet companion source')
  };
}

export function decodePetAssetResponse(raw: RawJsonValue): PetAssetResponse {
  const value = requireObject(raw, 'pet asset response');
  const schemaVersion = Math.trunc(num(pick(value, 'schemaVersion', 'schema_version'), 0));
  if (schemaVersion !== 1) throw new Error(`pet asset schema is unsupported: ${schemaVersion}`);
  const glbName = requireString(pick(value, 'glbName', 'glb_name'), 'pet asset name');
  const byteLength = Math.trunc(num(pick(value, 'byteLength', 'byte_length'), -1));
  if (byteLength < 0 || byteLength > 16 * 1024 * 1024) {
    throw new Error('pet asset byte length is outside the safety bound');
  }
  const sha256 = requireString(pick(value, 'sha256'), 'pet asset digest');
  if (!/^[0-9a-f]{64}$/u.test(sha256)) throw new Error('pet asset digest is invalid');
  const dataBase64 = requireString(pick(value, 'dataBase64', 'data_base64'), 'pet asset bytes');
  if (!dataBase64 || dataBase64.length > 24 * 1024 * 1024) {
    throw new Error('pet asset bytes are outside the safety bound');
  }
  return { schemaVersion, glbName, byteLength, sha256, dataBase64 };
}

export function decodePetAtlasResponse(raw: RawJsonValue): PetAtlasResponse {
  const value = requireObject(raw, 'pet atlas response');
  const schemaVersion = Math.trunc(num(pick(value, 'schemaVersion', 'schema_version'), 0));
  if (schemaVersion !== 1) throw new Error(`pet atlas schema is unsupported: ${schemaVersion}`);
  const petId = requireString(pick(value, 'petId', 'pet_id'), 'pet atlas pet id');
  const imageName = requireString(pick(value, 'imageName', 'image_name'), 'pet atlas image name');
  const mimeType = requireString(pick(value, 'mimeType', 'mime_type'), 'pet atlas mime type');
  if (mimeType !== 'image/webp' && mimeType !== 'image/png') throw new Error('pet atlas mime type is invalid');
  const byteLength = Math.trunc(num(pick(value, 'byteLength', 'byte_length'), -1));
  if (byteLength < 0 || byteLength > 8 * 1024 * 1024) {
    throw new Error('pet atlas byte length is outside the safety bound');
  }
  const sha256 = requireString(pick(value, 'sha256'), 'pet atlas digest');
  if (!/^[0-9a-f]{64}$/u.test(sha256)) throw new Error('pet atlas digest is invalid');
  const dataBase64 = requireString(pick(value, 'dataBase64', 'data_base64'), 'pet atlas bytes');
  if (!dataBase64 || dataBase64.length > 12 * 1024 * 1024) {
    throw new Error('pet atlas bytes are outside the safety bound');
  }
  return { schemaVersion, petId, imageName, mimeType, byteLength, sha256, dataBase64 };
}

export function normalizeMercuryPlatform(raw: string): MercuryDevicePlatform {
  const lower = raw.toLowerCase();
  if (lower.includes('ios') || lower.includes('iphone') || lower.includes('ipad')) return 'ios';
  if (lower.includes('android')) return 'android';
  if (lower.includes('mac')) return 'macos';
  if (lower.includes('linux')) return 'linux';
  return 'unknown';
}

export function normalizeMercuryKind(raw: string): MercurySessionKind {
  const lower = raw.toLowerCase();
  if (lower.includes('file')) return 'file';
  if (lower.includes('call') || lower.includes('voip')) return 'call';
  return 'screen-share';
}

export function normalizeMercuryState(raw: string): MercurySessionState {
  const lower = raw.toLowerCase();
  if (lower.includes('connect') || lower.includes('start')) return 'connecting';
  if (lower.includes('active') || lower.includes('stream')) return 'active';
  if (lower.includes('end') || lower.includes('stop') || lower.includes('done')) return 'ended';
  return 'staged';
}

export function normalizeMercuryCallPhase(raw: string): MercuryCallPhase {
  const lower = raw.toLowerCase();
  if (lower.includes('absent') || lower.includes('unsupported') || lower.includes('unavailable')) return 'capability-absent';
  if (lower.includes('ring') || lower.includes('incoming')) return 'ringing';
  if (lower.includes('stream') || lower.includes('active') || lower.includes('accepted') || lower.includes('viewer')) return 'streaming';
  if (lower.includes('cool') || lower.includes('end') || lower.includes('declin') || lower.includes('stop')) return 'cooldown';
  return 'idle';
}

export function isCapabilityAbsentError(e: unknown): boolean {
  const message = e instanceof Error ? e.message : String(e);
  return /unknown|unsupported|not implemented|no such method/i.test(message);
}

export function normalizeMercuryViewerStatus(
  raw: string,
  available: boolean,
  reason?: string
): MercuryViewerCapabilityStatus {
  const known: MercuryViewerCapabilityStatus[] = [
    'available',
    'built_without_gstreamer',
    'gstreamer_backend_unavailable',
    'gstreamer_vp9_decoder_missing',
    'gstreamer_video_sink_missing'
  ];
  if (known.includes(raw as MercuryViewerCapabilityStatus)) {
    return raw as MercuryViewerCapabilityStatus;
  }
  if (available) return 'available';
  if (reason && known.includes(reason as MercuryViewerCapabilityStatus)) {
    return reason as MercuryViewerCapabilityStatus;
  }
  return 'unknown';
}

export function mapMercuryViewerCapability(raw: RawJsonValue): MercuryViewerCapability {
  const available = pick(raw, 'available', 'capabilityAvailable', 'capability_available') === true;
  const rendererRaw = str(pick(raw, 'renderer', 'source'), 'unknown');
  const renderer = rendererRaw === 'media-gst' || /MediaCapture/i.test(rendererRaw)
    ? 'media-gst'
    : rendererRaw === 'stub'
      ? 'stub'
      : 'unknown';
  const reason = str(pick(raw, 'reason', 'detail', 'error')) || undefined;
  const status = normalizeMercuryViewerStatus(
    str(pick(raw, 'status', 'state')),
    available,
    reason
  );
  return {
    available,
    renderer,
    featureEnabled: pick(raw, 'featureEnabled', 'feature_enabled') === true,
    canDecodeVp9: pick(raw, 'canDecodeVp9', 'can_decode_vp9') === true,
    hasVideoSink: pick(raw, 'hasVideoSink', 'has_video_sink') === true,
    status,
    ...(reason ? { reason } : {}),
    ...(str(pick(raw, 'installHint', 'install_hint'))
      ? { installHint: str(pick(raw, 'installHint', 'install_hint')) }
      : {})
  };
}

export function mapMercuryMediaStatus(raw: RawJsonValue): MercuryMediaStatus {
  const absent = Boolean(pick(raw, 'capabilityAbsent', 'capability_absent'));
  const capability = pick(raw, 'capability');
  const viewerRaw = pick(raw, 'viewerCapability', 'viewer_capability');
  const viewerCapability = viewerRaw && typeof viewerRaw === 'object' && !Array.isArray(viewerRaw)
    ? mapMercuryViewerCapability(viewerRaw)
    : undefined;
  const availableRaw =
    pick(capability, 'available', 'capabilityAvailable', 'capability_available') ??
    pick(raw, 'capabilityAvailable', 'capability_available', 'available');
  const sessionRaw = pick(raw, 'activeSession', 'active_session', 'session');
  const sessionPeer = pick(sessionRaw, 'peer');
  const declaredDevices = arr(pick(raw, 'pairedDevices', 'paired_devices', 'devices', 'peers'));
  const deviceRows = declaredDevices.length > 0
    ? declaredDevices
    : sessionPeer && typeof sessionPeer === 'object' && !Array.isArray(sessionPeer)
      ? [sessionPeer]
      : [];
  const pairedDevices = deviceRows.map(
    (d, i): MercuryPairedDevice => ({
      id: str(pick(d, 'id', 'deviceID', 'deviceId', 'device_id', 'connectionID', 'connectionId'), `device-${i}`),
      name: str(pick(d, 'name', 'displayName', 'display_name', 'label'), `Device ${i + 1}`),
      platform: normalizeMercuryPlatform(str(pick(d, 'platform', 'kind', 'os'), 'unknown')),
      isOnline: Boolean(pick(d, 'isOnline', 'is_online', 'online')),
      lastSeenAt: str(pick(d, 'lastSeenAt', 'last_seen_at', 'updatedAt'), new Date(0).toISOString()),
      capabilities: arr(pick(d, 'capabilities', 'features')).map((capability) => str(capability)).filter(Boolean)
    })
  );
  const sessionPhase = str(pick(sessionRaw, 'phase', 'state', 'status')).toLowerCase();
  const activeSession =
    sessionRaw && typeof sessionRaw === 'object' && sessionPhase !== '' && sessionPhase !== 'idle'
      ? {
          kind: normalizeMercuryKind(str(pick(sessionRaw, 'kind', 'type'), 'screen-share')),
          state: normalizeMercuryState(str(pick(sessionRaw, 'state', 'phase', 'status'), 'staged')),
          peer: str(
            pick(sessionPeer, 'displayName', 'display_name', 'name') ??
              pick(sessionRaw, 'peerName', 'peer_name', 'deviceName'),
            'Paired device'
          ),
          requestId: str(pick(sessionRaw, 'requestID', 'requestId', 'request_id')) || undefined,
          startedAt: str(pick(sessionRaw, 'startedAt', 'started_at')) || undefined
        }
      : undefined;
  const daemonReason = str(
    pick(capability, 'detail', 'reason') ?? pick(raw, 'detail', 'reason')
  ) || undefined;
  return {
    capabilityAvailable: absent ? false : availableRaw === true,
    pairedDevices,
    activeSession,
    ...(viewerCapability ? { viewerCapability } : {}),
    ...(daemonReason ? { reason: daemonReason } : {})
  };
}

export function mapMercurySessionState(raw: RawJsonValue): MercuryMediaSessionState {
  const incomingCall = pick(raw, 'incomingCall', 'incoming_call');
  const activeSession = pick(raw, 'activeSession', 'active_session', 'session');
  const source =
    incomingCall && typeof incomingCall === 'object'
      ? incomingCall
      : activeSession && typeof activeSession === 'object'
        ? activeSession
        : raw;
  const peer = pick(source, 'peer');
  const absent = Boolean(pick(raw, 'capabilityAbsent', 'capability_absent'));
  const availableRaw = pick(raw, 'capabilityAvailable', 'capability_available', 'available');
  const phaseRaw = str(
    pick(raw, 'phase', 'state', 'status') ?? pick(source, 'phase', 'state', 'status'),
    absent ? 'capability-absent' : 'idle'
  );
  const phase = absent ? 'capability-absent' : normalizeMercuryCallPhase(phaseRaw);
  return {
    phase,
    requestId:
      str(
        pick(raw, 'requestID', 'requestId', 'request_id') ??
          pick(source, 'requestID', 'requestId', 'request_id')
      ) || undefined,
    peerName:
      str(
        pick(raw, 'peerName', 'peer_name', 'deviceName') ??
          pick(source, 'peerName', 'peer_name', 'deviceName') ??
          pick(peer, 'displayName', 'display_name', 'name')
      ) ||
      undefined,
    peerId:
      str(
        pick(raw, 'peerID', 'peerId', 'peer_id', 'deviceID', 'deviceId') ??
          pick(source, 'peerID', 'peerId', 'peer_id', 'deviceID', 'deviceId') ??
          pick(peer, 'connectionID', 'connectionId', 'id')
      ) || undefined,
    kind: normalizeMercuryKind(str(pick(raw, 'kind', 'type') ?? pick(source, 'kind', 'type'), 'call')),
    startedAt: str(pick(raw, 'startedAt', 'started_at') ?? pick(source, 'startedAt', 'started_at')) || undefined,
    endedAt: str(pick(raw, 'endedAt', 'ended_at') ?? pick(source, 'endedAt', 'ended_at')) || undefined,
    capabilityAvailable: absent ? false : availableRaw === undefined ? true : Boolean(availableRaw),
    raw
  };
}

export function mapMercuryCapability(raw: RawJsonValue): MercuryMediaCapability {
  const absent = Boolean(pick(raw, 'capabilityAbsent', 'capability_absent'));
  const availableRaw = pick(raw, 'available', 'capabilityAvailable', 'capability_available');
  const rendererRaw = str(pick(raw, 'renderer', 'source'), 'unknown');
  const renderer = rendererRaw === 'media-gst' || /MediaCapture/i.test(rendererRaw)
    ? 'media-gst'
    : rendererRaw === 'stub'
      ? 'stub'
      : 'unknown';
  const capabilities = arr(pick(raw, 'capabilities', 'features')).map((capability) => str(capability)).filter(Boolean);
  const codecs = obj(pick(raw, 'codecs'));
  const available = absent ? false : availableRaw === true;
  return {
    available,
    renderer,
    canReceiveCalls:
      Boolean(pick(raw, 'canReceiveCalls', 'can_receive_calls')) || capabilities.includes('call.receive') || available,
    canPlayCallAudio:
      !absent && (Boolean(pick(raw, 'supportsCallAudioPlayback', 'supports_call_audio_playback'))
        || Boolean(pick(codecs, 'opusPlayback', 'opus_playback'))
        || capabilities.includes('call.audio.playback')),
    canViewScreenShare:
      Boolean(pick(raw, 'canViewScreenShare', 'can_view_screen_share')) ||
      capabilities.includes('mirror.viewer') ||
      (available && Boolean(pick(raw, 'supportsDaemonToShellFrames', 'supports_daemon_to_shell_frames'))),
    reason: str(pick(raw, 'reason', 'detail', 'error')) || undefined
  };
}

export function normalizeFileDirection(raw: string): MercuryFileTransferDirection {
  return raw.toLowerCase().includes('out') ? 'outbound' : 'inbound';
}

export function normalizeFilePhase(raw: string): MercuryFileTransferPhase {
  const compact = raw.replace(/[_\-\s]/g, '').toLowerCase();
  if (compact.includes('pending') || compact.includes('offer') && !compact.includes('offered')) return 'pendingAccept';
  if (compact.includes('download') || compact.includes('fetch')) return 'downloading';
  if (compact.includes('send') || compact.includes('publish')) return 'sending';
  if (compact.includes('offered') || compact.includes('advertised')) return 'offered';
  if (compact.includes('complete') || compact.includes('done') || compact.includes('success')) return 'completed';
  if (compact.includes('decline') || compact.includes('reject')) return 'declined';
  if (compact.includes('fail') || compact.includes('error')) return 'failed';
  return 'pendingAccept';
}

export function normalizeFileErrorCode(raw: RawJsonValue): MercuryFileTransferErrorCode | undefined {
  const compact = str(raw).replace(/[_\-\s]/g, '').toLowerCase();
  const codes: MercuryFileTransferErrorCode[] = [
    'capabilityAbsent',
    'invalidRequest',
    'transferNotFound',
    'localFileMissing',
    'noControlRoute',
    'publishFailed',
    'fetchFailed',
    'ioFailed',
    'peerRejected'
  ];
  return codes.find((code) => code.toLowerCase() === compact);
}

export function mapMercuryFilePeer(raw: RawJsonValue): MercuryFilePeer | undefined {
  if (!raw || typeof raw !== 'object') return undefined;
  return {
    id: str(pick(raw, 'connectionID', 'connectionId', 'peerID', 'peerId', 'id'), 'peer'),
    name: str(pick(raw, 'displayName', 'display_name', 'name', 'peerName', 'peer_name'), 'Paired device'),
    isOnline: Boolean(pick(raw, 'isOnline', 'is_online', 'online')),
    lastSeenAt: str(pick(raw, 'lastSeenAt', 'last_seen_at', 'updatedAt'), new Date(0).toISOString()),
    capabilities: arr(pick(raw, 'capabilities', 'features')).map((capability) => str(capability)).filter(Boolean)
  };
}

export function mapMercuryFileProgress(raw: RawJsonValue, size: number): MercuryFileTransferProgress {
  const bytesTransferred = num(pick(raw, 'bytesTransferred', 'bytes_transferred'));
  const bytesTotal = num(pick(raw, 'bytesTotal', 'bytes_total'), size);
  const fractionRaw = pick(raw, 'fraction');
  const fallbackFraction = bytesTotal > 0 ? bytesTransferred / bytesTotal : 0;
  return {
    bytesTransferred,
    bytesTotal,
    fraction: Math.max(0, Math.min(1, num(fractionRaw, fallbackFraction)))
  };
}

export function mapMercuryFileTransfer(raw: RawJsonValue, index = 0): MercuryFileTransfer {
  const size = num(pick(raw, 'size', 'byteCount', 'bytesTotal', 'bytes_total'));
  const progressRaw = pick(raw, 'progress') ?? {};
  const now = new Date().toISOString();
  return {
    transferID: str(pick(raw, 'transferID', 'transferId', 'transfer_id'), `transfer-${index}`),
    manifestID: str(pick(raw, 'manifestID', 'manifestId', 'manifest_id'), `manifest-${index}`),
    direction: normalizeFileDirection(str(pick(raw, 'direction'), 'inbound')),
    phase: normalizeFilePhase(str(pick(raw, 'phase', 'state', 'status'), 'pendingAccept')),
    filename: str(pick(raw, 'filename', 'fileName', 'name'), 'untitled'),
    mime: str(pick(raw, 'mime', 'contentType', 'content_type'), 'application/octet-stream'),
    size,
    peer: mapMercuryFilePeer(pick(raw, 'peer')),
    progress: mapMercuryFileProgress(progressRaw, size),
    localPath: str(pick(raw, 'localPath', 'local_path', 'path')) || undefined,
    errorCode: normalizeFileErrorCode(pick(raw, 'errorCode', 'error_code')),
    detail: str(pick(raw, 'detail', 'reason', 'error')) || undefined,
    createdAt: str(pick(raw, 'createdAt', 'created_at'), now),
    updatedAt: str(pick(raw, 'updatedAt', 'updated_at'), now),
    completedAt: str(pick(raw, 'completedAt', 'completed_at')) || undefined
  };
}

export function mapMercuryFileOfferList(raw: RawJsonValue): MercuryFileOfferListResponse {
  const source = pick(raw, 'result') ?? raw;
  const absent = Boolean(pick(source, 'capabilityAbsent', 'capability_absent'));
  const availableRaw = pick(source, 'capabilityAvailable', 'capability_available', 'available');
  return {
    capabilityAvailable: absent ? false : availableRaw === undefined ? true : Boolean(availableRaw),
    downloadDirectory: str(pick(source, 'downloadDirectory', 'download_directory')) || undefined,
    transfers: arr(pick(source, 'transfers', 'offers', 'files')).map((transfer, index) =>
      mapMercuryFileTransfer(transfer, index)
    ),
    detail: str(pick(source, 'detail', 'reason', 'error')) || undefined
  };
}

export function mapMercuryFileAction(raw: RawJsonValue): MercuryFileTransferActionResponse {
  const source = pick(raw, 'result') ?? raw;
  const transferRaw = pick(source, 'transfer', 'fileTransfer', 'file_transfer');
  return {
    accepted: Boolean(pick(source, 'accepted', 'ok')),
    transfer: transferRaw && typeof transferRaw === 'object' ? mapMercuryFileTransfer(transferRaw) : undefined,
    errorCode: normalizeFileErrorCode(pick(source, 'errorCode', 'error_code')),
    detail: str(pick(source, 'detail', 'reason', 'error')) || undefined
  };
}

/** Decode a native outgoing-file chooser result without accepting renderer paths. */
export function mapMercuryFilePickerPath(raw: RawJsonValue): string | null {
  if (raw === null || raw === undefined) return null;
  const path = str(raw);
  if (
    !path.startsWith('/')
    || path.length > 4096
    || [...path].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)
    || path.includes('\\')
  ) {
    throw new Error('Native media file dialog returned an unsafe path.');
  }
  const segments = path.split('/');
  const filename = segments.at(-1) ?? '';
  if (
    !filename
    || filename === '.'
    || filename === '..'
    || filename.length > 255
    || segments.slice(1, -1).some((segment) => segment.length === 0 || segment === '.' || segment === '..')
  ) {
    throw new Error('Native media file dialog returned an unsafe path.');
  }
  return path;
}

export function mapComputerUsePanicHalt(
  raw: RawJsonValue,
  source: ComputerUsePanicSource
): ComputerUsePanicHaltResult {
  return {
    sessionId: str(pick(raw, 'sessionId', 'session_id'), '*'),
    endedAt: str(pick(raw, 'endedAt', 'ended_at'), new Date().toISOString()),
    auditHeadHashHex: str(pick(raw, 'auditHeadHashHex', 'audit_head_hash_hex')),
    source,
    raw
  };
}

export const COMPUTER_USE_INVOKE_STATUSES: readonly ComputerUseInvokeResponseStatus[] = [
  'executed',
  'denied',
  'awaiting_approval',
  'error'
];

/** Decode the daemon's Swift Codable response without hiding a malformed result. */
export function decodeComputerUseInvokeResponse(raw: RawJsonValue): ComputerUseInvokeResponse {
  const direct = obj(raw);
  const source = typeof direct.status === 'string'
    ? direct
    : requireObject(pick(raw, 'result'), 'computer-use invoke response');
  const status = requireString(source.status, 'computer-use invoke status');
  if (!COMPUTER_USE_INVOKE_STATUSES.includes(status as ComputerUseInvokeResponseStatus)) {
    throw new Error(`computer-use invoke returned unsupported status: ${status}`);
  }
  const sessionId = requireString(
    pick(source, 'sessionId', 'sessionID', 'session_id'),
    'computer-use invoke sessionId'
  );
  const callID = requireString(
    pick(source, 'callID', 'callId', 'call_id'),
    'computer-use invoke callID'
  );
  const auditEntryIndexRaw = pick(source, 'auditEntryIndex', 'audit_entry_index');
  const auditEntryIndex = typeof auditEntryIndexRaw === 'number'
    && Number.isSafeInteger(auditEntryIndexRaw)
    && auditEntryIndexRaw >= 0
    ? auditEntryIndexRaw
    : undefined;
  const optionalString = (...keys: string[]): string | undefined => {
    const value = pick(source, ...keys);
    return typeof value === 'string' && value.length > 0 ? value : undefined;
  };
  return {
    sessionId,
    callID,
    status: status as ComputerUseInvokeResponseStatus,
    approvalId: optionalString('approvalId', 'approvalID', 'approval_id'),
    denyReason: optionalString('denyReason', 'deny_reason', 'reason'),
    auditEntryIndex,
    auditHeadHashHex: optionalString('auditHeadHashHex', 'audit_head_hash_hex'),
    result: source.result
  };
}
