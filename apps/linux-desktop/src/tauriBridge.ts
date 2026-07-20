import { Channel, invoke } from '@tauri-apps/api/core';
import type { DaemonHealth } from './daemonClient.js';
import { decodeRuntimeCapabilityManifest } from './runtimeCapabilities.js';
import { decodeLinuxOnboardingSnapshot } from './onboardingStore.js';
import type {
  ComputerUseSessionAuthorityStatus,
  LinuxShellBridge
} from './tauriBridgeTypes.js';
import {
  DATABASE_CODE_DEFAULT_RESULTS,
  DATABASE_CODE_MAX_CONTEXT_BYTES
} from './tauriBridgeTypes.js';
import type { RawJsonValue } from './tauriBridgeRaw.js';
import {
  str,
  obj,
  pick
} from './tauriBridgeRaw.js';
import {
  decodeDaemonSubscriptionResponse,
  decodeDaemonSubscriptionStopResponse,
  mapUsageSummary,
  mapProviderCatalog,
  mapSessionList,
  mapSessionHistory,
  mapSessionReplay,
  decodeChatThreadList,
  decodeChatThreadGet,
  decodeChatMessageAppend,
  decodeChatAttachmentUpload,
  decodeGatewayAttachmentCapability,
  assertAppendEcho,
  decodeUsageInsights,
  mapMissionHealth,
  mapMissionList,
  mapMissionDetail,
  mapMissionMutation
} from './tauriBridgeCoreDecoders.js';
import {
  mapConfigSnapshot,
  mapDbStatus,
  mapProjectRecord,
  mapProjectDeleteResult,
  mapProjectReassignResult,
  mapProjectHistory,
  mapProjectList,
  mapMemoryBoundaries,
  mapMemoryReviewInbox,
  mapDatabaseWorkspaceStatus,
  mapDatabaseIndexAction,
  mapDatabaseSnapshot,
  mapDatabaseRecoveryBundleExport,
  mapDatabaseRecoveryStatus,
  mapDatabaseRecoveryBundleImport,
  mapDatabaseCodeSearch,
  mapDatabaseCodeContextPack,
  clampDatabaseCodeLimit,
  normalizeDatabaseCodeQuery,
  mapAccountStatus,
  mapAccountCloudDataDeletionResult,
  mapAccountSignInOperation,
  mapMembershipStatus,
  mapMembershipCheckoutUrl,
  mapDiagnosticsExport,
  mapAppVersionInfo,
  decodeLinuxUpdateStatus,
  decodeSmartHubCommandResponse,
  mapIntegrationsStatus
} from './tauriBridgeSystemDecoders.js';
import {
  mapTextExpansionSnippet,
  mapTextExpansionSnapshot,
  mapTextExpansionConsent,
  mapTextExpansionEngineRuntimeStatus,
  snapshotFromMutation,
  mapProxyRouteLog,
  mapLinuxPrivacyInventory,
  mapLinuxPrivacyDeletionPreview,
  mapLinuxPrivacyDeletionResult,
  mapLinuxPrivacyExport,
  mapLinuxPrivacyRetentionStatus,
  mapLinuxPrivacyRetentionApply,
  mapNotificationConfig,
  mapNotificationHealth,
  mapNotificationCommand,
  decodeNativeNotificationCapabilities,
  decodeNativeNotificationResult,
  decodeNativeNotificationActionEvents,
  decodeNativeShortcutStatus,
  decodeLaunchAtLoginStatus,
  decodePetCompanionStatus,
  isCapabilityAbsentError,
  mapMercuryMediaStatus,
  mapMercurySessionState,
  mapMercuryCapability,
  mapMercuryFileOfferList,
  mapMercuryFileAction,
  mapComputerUsePanicHalt,
  decodeComputerUseInvokeResponse
} from './tauriBridgePlatformDecoders.js';

export * from './tauriBridgeTypes.js';
export {
  computeCacheHitRatePct,
  decodeChatAttachmentUpload,
  decodeChatMessageAppend,
  decodeChatThreadGet,
  decodeChatThreadList,
  decodeDaemonSubscriptionResponse,
  decodeDaemonSubscriptionStopResponse,
  decodeGatewayAttachmentCapability,
  decodeUsageInsights,
  mapMissionDetail,
  mapMissionList,
  mapMissionSnapshot,
  mapProviderCatalog
} from './tauriBridgeCoreDecoders.js';
export {
  decodeLinuxUpdateStatus,
  decodeSmartHubCommandResponse,
  isSafeDiagnosticsPath,
  isSafeDiagnosticsPreview
} from './tauriBridgeSystemDecoders.js';
export {
  decodeComputerUseInvokeResponse,
  decodeLaunchAtLoginStatus,
  decodeNativeNotificationActionEvent,
  decodeNativeNotificationActionEvents,
  decodeNativeNotificationCapabilities,
  decodeNativeNotificationResult,
  decodeNativeShortcutStatus,
  decodePetCompanionStatus,
  defaultNotificationConfig
} from './tauriBridgePlatformDecoders.js';


export async function loadShellBridge(): Promise<LinuxShellBridge | null> {
  if (!('__TAURI_INTERNALS__' in window)) {
    return null;
  }
  return {
    daemonHealth: () => invoke<DaemonHealth>('daemon_health'),
    runtimeCapabilities: async () =>
      decodeRuntimeCapabilityManifest(await invoke<RawJsonValue>('runtime_capabilities')),
    gatewayProbe: () => invoke<boolean>('gateway_probe'),
    gatewayAttachmentCapability: async (model, mimeType) =>
      decodeGatewayAttachmentCapability(
        await invoke<RawJsonValue>('gateway_attachment_capability', { model, mimeType })
      ),
    chatAttachmentUpload: async (request) =>
      decodeChatAttachmentUpload(await invoke<RawJsonValue>('chat_attachment_upload', { request })),
    gatewayChatStream: (request, onChunk) => {
      const onEvent = new Channel<string>();
      onEvent.onmessage = onChunk;
      return invoke<void>('gateway_chat_stream', { request, onEvent });
    },
    gatewayChatCancel: (requestId) => invoke<void>('gateway_chat_cancel', { requestId }),
    openDashboard: () => invoke<void>('open_dashboard'),
    initialDeepLinkRoute: () => invoke<string | null>('initial_deep_link_route'),
    forwardedDeepLinkRoute: () => invoke<string | null>('forwarded_deep_link_route'),
    initialNotificationActions: async () =>
      decodeNativeNotificationActionEvents(await invoke<RawJsonValue>('initial_notification_actions')),
    quitApp: () => invoke<void>('quit_app'),
    trayDegraded: () => invoke<boolean>('tray_degraded'),
    measurePerfOperation: (name) =>
      invoke<{
        name: string;
        ms: number;
        source: string;
        ok: boolean;
        detail?: string;
      }>('measure_perf_operation', { name }),
    onboardingSnapshot: async () =>
      decodeLinuxOnboardingSnapshot(await invoke<RawJsonValue>('onboarding_snapshot')),
    onboardingAction: async (request) =>
      decodeLinuxOnboardingSnapshot(
        await invoke<RawJsonValue>('onboarding_action', { request })
      ),
    onboardingReset: async () =>
      decodeLinuxOnboardingSnapshot(await invoke<RawJsonValue>('onboarding_reset')),
    subscriptionStart: async (request) =>
      decodeDaemonSubscriptionResponse(
        await invoke<RawJsonValue>('subscription_start', { request })
      ),
    subscriptionResume: async (request) =>
      decodeDaemonSubscriptionResponse(
        await invoke<RawJsonValue>('subscription_resume', { request })
      ),
    subscriptionStop: async (request) =>
      decodeDaemonSubscriptionStopResponse(
        await invoke<RawJsonValue>('subscription_stop', { request })
      ),

    // P01 — daemon.usage.recent → aggregated summary
    usageSummary: async () => {
      const raw = await invoke<RawJsonValue>('usage_summary');
      return mapUsageSummary(raw);
    },
    // P02 — daemon.config.get → provider catalog
    providerCatalog: async () => {
      const raw = await invoke<RawJsonValue>('provider_catalog');
      return mapProviderCatalog(raw);
    },
    // P03 — daemon.usage.recent → session list (client-side paginated by store)
    sessionList: async () => {
      const raw = await invoke<RawJsonValue>('session_list');
      return mapSessionList(raw);
    },
    // P03 — daemon.usage.history → explicit complete-history snapshot
    sessionHistory: async () => {
      const raw = await invoke<RawJsonValue>('session_history');
      return mapSessionHistory(raw);
    },
    // P03 — daemon.search.query → session search
    sessionSearch: async (query) => {
      const raw = await invoke<RawJsonValue>('session_search', { query });
      return mapSessionList(raw);
    },
    sessionReplay: async (sessionID) =>
      mapSessionReplay(await invoke<RawJsonValue>('session_replay', { sessionId: sessionID })),
    sessionResume: async (sessionID) =>
      mapSessionReplay(await invoke<RawJsonValue>('session_resume', { sessionId: sessionID })),
    // Exact persisted chat authority; unlike P03, these never derive chat from usage rows.
    chatThreadList: async (query, limit = 100) => {
      const raw = await invoke<RawJsonValue>('chat_thread_list', { query: query || null, limit });
      return decodeChatThreadList(raw);
    },
    chatThreadGet: async (threadID, maxMessages = 500, before) => {
      const args: {
        threadId: string;
        maxMessages: number;
        beforeTimestamp?: string;
        beforeMessageId?: string;
      } = { threadId: threadID, maxMessages };
      if (before) {
        args.beforeTimestamp = before.timestamp;
        args.beforeMessageId = before.messageID;
      }
      const raw = await invoke<RawJsonValue>('chat_thread_get', args);
      return decodeChatThreadGet(raw);
    },
    chatMessageAppend: async (request) => {
      const raw = await invoke<RawJsonValue>('chat_message_append', { request });
      const result = decodeChatMessageAppend(raw);
      assertAppendEcho(request, result);
      return result;
    },
    // P05 — daemon.usage.recent → insights aggregation
    usageInsights: async () => {
      const raw = await invoke<RawJsonValue>('usage_insights');
      return decodeUsageInsights(raw);
    },
    // P06 — daemon.mission.list + pending approvals
    missionList: async () => {
      const raw = await invoke<RawJsonValue>('mission_list');
      return mapMissionList(raw);
    },
    // Canonical daemon.mission.get — detail fields are returned by the
    // snapshot itself; there is no separate history/evidence RPC to invent.
    missionGet: async (id) => {
      const raw = await invoke<RawJsonValue>('mission_get', { missionId: id });
      return mapMissionDetail(raw);
    },
    missionHealth: async (id) => {
      const raw = await invoke<RawJsonValue>('mission_health', { missionId: id });
      return mapMissionHealth(raw);
    },
    // P06 — daemon.mission.approve / daemon.mission.cancel
    missionApprovalDecision: async (id, decision) => {
      await invoke<void>('mission_approval_decision', { id, decision });
    },
    // Canonical daemon.mission.cancel for an explicit cancellation action.
    missionCancel: async (id, note) => {
      const raw = await invoke<RawJsonValue>('mission_cancel', { missionId: id, note });
      return mapMissionDetail(raw);
    },
    // P06 — daemon.mission.create
    missionCreate: async (input) => {
      const raw = await invoke<RawJsonValue>('mission_create', input);
      return mapMissionMutation(raw);
    },
    // P07 — daemon.config.get → read-only settings snapshot
    configSnapshot: async () => {
      const raw = await invoke<RawJsonValue>('config_snapshot');
      return mapConfigSnapshot(raw);
    },
    configUpdate: async (snapshot) => {
      const raw = await invoke<RawJsonValue>('config_update', { snapshot });
      return snapshotFromMutation(raw);
    },
    providerCredentialSlotUpsert: async (params) => {
      const raw = await invoke<RawJsonValue>('provider_credential_slot_upsert', { params });
      return snapshotFromMutation(raw);
    },
    providerCredentialSlotRemove: async (providerID, slotID) => {
      const raw = await invoke<RawJsonValue>('provider_credential_slot_remove', { providerId: providerID, slotId: slotID });
      return snapshotFromMutation(raw);
    },
    providerModelVariantUpsert: async (providerID, variant) => {
      const raw = await invoke<RawJsonValue>('provider_model_variant_upsert', { providerId: providerID, variant });
      return snapshotFromMutation(raw);
    },
    providerModelVariantRemove: async (providerID, variantID) => {
      const raw = await invoke<RawJsonValue>('provider_model_variant_remove', { providerId: providerID, variantId: variantID });
      return snapshotFromMutation(raw);
    },
    providerModelAliasUpsert: async (providerID, alias) => {
      const raw = await invoke<RawJsonValue>('provider_model_alias_upsert', { providerId: providerID, alias });
      return snapshotFromMutation(raw);
    },
    providerModelAliasRemove: async (providerID, aliasID) => {
      const raw = await invoke<RawJsonValue>('provider_model_alias_remove', { providerId: providerID, aliasId: aliasID });
      return snapshotFromMutation(raw);
    },
    providerCustomModelUpsert: async (providerID, customModel) => {
      const raw = await invoke<RawJsonValue>('provider_custom_model_upsert', { providerId: providerID, customModel });
      return snapshotFromMutation(raw);
    },
    providerCustomModelRemove: async (providerID, modelID) => {
      const raw = await invoke<RawJsonValue>('provider_custom_model_remove', { providerId: providerID, modelId: modelID });
      return snapshotFromMutation(raw);
    },
    providerModelDisplayNameSet: async (providerID, modelID, displayName) => {
      const raw = await invoke<RawJsonValue>('provider_model_display_name_set', { providerId: providerID, modelId: modelID, displayName });
      return snapshotFromMutation(raw);
    },
    providerModelDisplayNameClear: async (providerID, modelID) => {
      const raw = await invoke<RawJsonValue>('provider_model_display_name_clear', { providerId: providerID, modelId: modelID });
      return snapshotFromMutation(raw);
    },
    proxyRouteLogRecent: async (limit) => {
      const raw = await invoke<RawJsonValue>('proxy_route_log_recent', { limit });
      return mapProxyRouteLog(raw);
    },
    proxyRouteLogClear: async () => {
      const raw = await invoke<RawJsonValue>('proxy_route_log_clear');
      return Boolean(pick(raw, 'cleared'));
    },
    linuxPrivacyInventory: async () => {
      const raw = await invoke<RawJsonValue>('linux_privacy_inventory');
      return mapLinuxPrivacyInventory(raw);
    },
    linuxPrivacyDeletionPreview: async (stores) => {
      const raw = await invoke<RawJsonValue>('linux_privacy_deletion_preview', { stores });
      return mapLinuxPrivacyDeletionPreview(raw);
    },
    linuxPrivacyDeletionExecute: async (request) => {
      const raw = await invoke<RawJsonValue>('linux_privacy_deletion_execute', { request });
      return mapLinuxPrivacyDeletionResult(raw);
    },
    linuxPrivacyExport: async (request) => {
      const raw = await invoke<RawJsonValue>('linux_privacy_export', { request });
      return mapLinuxPrivacyExport(raw);
    },
    linuxPrivacyRetentionStatus: async () => {
      const raw = await invoke<RawJsonValue>('linux_privacy_retention_status');
      return mapLinuxPrivacyRetentionStatus(raw);
    },
    linuxPrivacyRetentionApply: async (request) => {
      const raw = await invoke<RawJsonValue>('linux_privacy_retention_apply', { request });
      return mapLinuxPrivacyRetentionApply(raw);
    },
    notificationConfigGet: async () => {
      const raw = await invoke<RawJsonValue>('notification_config_get');
      return mapNotificationConfig(raw);
    },
    notificationConfigUpdate: async (config) => {
      const raw = await invoke<RawJsonValue>('notification_config_update', { config });
      return mapNotificationConfig(raw);
    },
    notificationHealth: async () => {
      const raw = await invoke<RawJsonValue>('notification_health');
      return mapNotificationHealth(raw);
    },
    notificationCommand: async (command, args = []) => {
      const raw = await invoke<RawJsonValue>('notification_command', { command, arguments: args });
      return mapNotificationCommand(raw);
    },
    nativeNotificationCapabilities: async () =>
      decodeNativeNotificationCapabilities(await invoke<RawJsonValue>('native_notification_capabilities')),
    nativeNotificationShow: async (request) =>
      decodeNativeNotificationResult(await invoke<RawJsonValue>('native_notification_show', { request })),
    nativeShortcutStatus: async () =>
      decodeNativeShortcutStatus(await invoke<RawJsonValue>('native_shortcut_status')),
    launchAtLoginStatus: async () =>
      decodeLaunchAtLoginStatus(await invoke<RawJsonValue>('launch_at_login_status')),
    launchAtLoginSet: async (enabled) =>
      decodeLaunchAtLoginStatus(await invoke<RawJsonValue>('launch_at_login_set', { enabled })),
    petCompanionStatus: async () =>
      decodePetCompanionStatus(await invoke<RawJsonValue>('pet_companion_status')),
    // P29 — authenticated daemon-owned encrypted text-expansion storage.
    textExpansionList: async () => {
      const raw = await invoke<RawJsonValue>('text_expansion_list');
      return mapTextExpansionSnapshot(raw);
    },
    textExpansionUpsert: async (snippet) => {
      const raw = await invoke<RawJsonValue>('text_expansion_upsert', { snippet });
      return mapTextExpansionSnippet(raw);
    },
    textExpansionDelete: async (id) => {
      const raw = await invoke<RawJsonValue>('text_expansion_delete', { id });
      return mapTextExpansionSnapshot(raw);
    },
    textExpansionConsentUpdate: async (consent) => {
      const raw = await invoke<RawJsonValue>('text_expansion_consent_update', { consent });
      return mapTextExpansionConsent(raw);
    },
    textExpansionEngineStatus: async () => {
      const raw = await invoke<RawJsonValue>('text_expansion_engine_status');
      return mapTextExpansionEngineRuntimeStatus(raw);
    },
    textExpansionEngineStart: async (request) => {
      const raw = await invoke<RawJsonValue>('text_expansion_engine_start', {
        request: { consentAcknowledged: request.consentAcknowledged, timeoutMillis: request.timeoutMillis ?? 1_000 }
      });
      return mapTextExpansionEngineRuntimeStatus(raw);
    },
    textExpansionEngineStop: async (request = {}) => {
      const raw = await invoke<RawJsonValue>('text_expansion_engine_stop', {
        request: { timeoutMillis: request.timeoutMillis ?? 500 }
      });
      return mapTextExpansionEngineRuntimeStatus(raw);
    },
    textExpansionEngineExpand: async (request) => {
      const raw = await invoke<RawJsonValue>('text_expansion_engine_expand', {
        request: {
          trigger: request.trigger,
          context: {
            inspectable: request.context.inspectable,
            isSecureField: request.context.isSecureField ?? null,
            applicationID: request.context.applicationID ?? null,
            role: request.context.role ?? null,
            inputPurpose: request.context.inputPurpose ?? null
          },
          timeoutMillis: request.timeoutMillis ?? 1_000,
          requestID: request.requestID ?? globalThis.crypto?.randomUUID?.() ?? `text-expansion-${Date.now()}-${Math.random().toString(36).slice(2)}`
        }
      });
      const value = obj(raw);
      return {
        expanded: Boolean(pick(value, 'expanded')),
        replacement: typeof pick(value, 'replacement') === 'string' ? String(pick(value, 'replacement')) : null
      };
    },
    // P07 — derived from daemon.config.get + daemon.health
    dbStatus: async () => {
      const raw = await invoke<RawJsonValue>('db_status');
      return mapDbStatus(raw);
    },
    // P07 — daemon.controller.project.list
    projectList: async () => {
      const raw = await invoke<RawJsonValue>('project_list');
      return mapProjectList(raw);
    },
    // P19 — daemon.controller.project.get
    projectGet: async (projectSlug) => {
      const raw = await invoke<RawJsonValue>('project_get', { projectSlug });
      return mapProjectRecord(raw);
    },
    // P19 — daemon.controller.project.upsert
    projectUpsert: async (project) => {
      const raw = await invoke<RawJsonValue>('project_upsert', { project });
      return mapProjectRecord(raw);
    },
    // P19 — daemon.controller.project.delete
    projectDelete: async (projectSlug) => {
      const raw = await invoke<RawJsonValue>('project_delete', { projectSlug });
      return mapProjectDeleteResult(raw);
    },
    // P19 — daemon.controller.project.reassign
    projectReassign: async (sourceProjectSlug, targetProjectSlug) => {
      const raw = await invoke<RawJsonValue>('project_reassign', { sourceProjectSlug, targetProjectSlug });
      return mapProjectReassignResult(raw);
    },
    // P19 — daemon.controller.summary recent events scoped to one project.
    projectHistory: async (projectSlug) => {
      const raw = await invoke<RawJsonValue>('project_history', { projectSlug });
      return mapProjectHistory(raw, projectSlug);
    },
    // P07 — daemon.memory.analytics
    memoryBoundaries: async () => {
      const raw = await invoke<RawJsonValue>('memory_boundaries');
      return mapMemoryBoundaries(raw);
    },
    // P07 — daemon.memory.recall + daemon.memory.audit_trail
    memoryReviewInbox: async () => {
      const raw = await invoke<RawJsonValue>('memory_review_inbox');
      return mapMemoryReviewInbox(raw);
    },
    // P07 — reject maps to forget. Approval requires the real memory body and
    // must use memorySetStatus; never invent an approved placeholder here.
    memoryReviewDecision: async (id, decision) => {
      if (decision === 'rejected') {
        await invoke<RawJsonValue>('memory_set_status', {
          action: 'reject',
          payload: { memoryID: id }
        });
        return;
      }
      if (decision === 'approved') {
        throw new Error(
          'memoryReviewDecision cannot approve without body text; use memorySetStatus({ text }) from the store.'
        );
      }
    },
    // P07 — daemon.code.index_status + explore + diagnostics + ops_diagnostics
    databaseWorkspaceStatus: async (projectPath) => {
      const raw = await invoke<RawJsonValue>('database_workspace_status', { projectPath });
      return mapDatabaseWorkspaceStatus(raw);
    },
    // P07 — daemon.code.index_project
    databaseIndexProject: async (projectPath) => {
      const raw = await invoke<RawJsonValue>('database_index_project', { projectPath });
      return mapDatabaseIndexAction(raw);
    },
    // P07 — daemon.code.watch_project (poll-only on Linux)
    databaseWatchProject: async (projectPath) => {
      const raw = await invoke<RawJsonValue>('database_watch_project', { projectPath });
      return mapDatabaseIndexAction(raw);
    },
    // P07 — bounded encrypted project-code database snapshot/recovery.
    databaseSnapshot: async (destinationPath, maxBytes) => {
      const raw = await invoke<RawJsonValue>('database_snapshot', {
        destinationPath,
        maxBytes: maxBytes == null ? undefined : Math.max(1, Math.min(512 * 1_024 * 1_024, Math.trunc(maxBytes)))
      });
      return mapDatabaseSnapshot(raw, false);
    },
    databaseRestore: async (snapshotPath, maxBytes) => {
      const raw = await invoke<RawJsonValue>('database_restore', {
        snapshotPath,
        maxBytes: maxBytes == null ? undefined : Math.max(1, Math.min(512 * 1_024 * 1_024, Math.trunc(maxBytes)))
      });
      return mapDatabaseSnapshot(raw, true);
    },
    // P22 — read-only recovery posture. The daemon decides whether key
    // custody, database presence, and integrity verification are each proven.
    databaseRecoveryBundleStatus: async () => {
      const raw = await invoke<RawJsonValue>('database_recovery_bundle_status');
      return mapDatabaseRecoveryStatus(raw);
    },
    // P22 — daemon-owned passphrase recovery bundle. Passphrases stay in the
    // native invoke/RPC call and are never persisted in Zustand or web storage.
    databaseRecoveryBundleExport: async (request) => {
      const raw = await invoke<RawJsonValue>('database_recovery_bundle_export', {
        destinationPath: request.destinationPath,
        passphrase: request.passphrase
      });
      return mapDatabaseRecoveryBundleExport(raw);
    },
    databaseRecoveryBundleImport: async (request) => {
      const raw = await invoke<RawJsonValue>('database_recovery_bundle_import', {
        sourcePath: request.sourcePath,
        passphrase: request.passphrase
      });
      return mapDatabaseRecoveryBundleImport(raw);
    },
    // P22 — daemon.code.search / daemon.code.context_pack. The daemon owns
    // index availability and trust wrapping; the shell only clamps bounded
    // reads and maps the typed response.
    databaseCodeSearch: async (request) => {
      const raw = await invoke<RawJsonValue>('database_code_search', {
        query: normalizeDatabaseCodeQuery(request.query),
        projectPath: request.projectPath,
        limit: clampDatabaseCodeLimit(request.limit, DATABASE_CODE_DEFAULT_RESULTS)
      });
      return mapDatabaseCodeSearch(raw);
    },
    databaseCodeContextPack: async (request) => {
      const raw = await invoke<RawJsonValue>('database_code_context_pack', {
        query: normalizeDatabaseCodeQuery(request.query),
        projectPath: request.projectPath,
        limit: clampDatabaseCodeLimit(request.limit, 10),
        maxBytes: Math.max(1_024, Math.min(DATABASE_CODE_MAX_CONTEXT_BYTES, Math.trunc(request.maxBytes ?? DATABASE_CODE_MAX_CONTEXT_BYTES)))
      });
      return mapDatabaseCodeContextPack(raw);
    },
    // P08 — daemon-owned browser PKCE and lower-trust Linux identity.
    accountStatus: async () => {
      const raw = await invoke<RawJsonValue>('account_status');
      return mapAccountStatus(raw);
    },
    accountDeleteCloudData: async (confirmation) => {
      const raw = await invoke<RawJsonValue>('account_delete_cloud_data', { confirmation });
      return mapAccountCloudDataDeletionResult(raw);
    },
    accountBeginSignIn: async () => {
      const raw = await invoke<RawJsonValue>('account_begin_sign_in');
      return mapAccountSignInOperation(raw);
    },
    accountCancelSignIn: async (operationID) => {
      const raw = await invoke<RawJsonValue>('account_cancel_sign_in', { operationId: operationID });
      return mapAccountStatus(raw);
    },
    accountRotateIdentity: async () => {
      const raw = await invoke<RawJsonValue>('account_rotate_identity');
      return mapAccountStatus(raw);
    },
    accountSignOut: async () => {
      const raw = await invoke<RawJsonValue>('account_sign_out');
      return mapAccountStatus(raw);
    },
    // P10 — daemon-owned membership data; fail closed if absent.
    membershipStatus: async () => {
      const raw = await invoke<RawJsonValue>('membership_status');
      return mapMembershipStatus(raw);
    },
    // P10 — daemon-minted URL only; opened externally by membershipStore.
    membershipCheckoutUrl: async () => {
      const raw = await invoke<RawJsonValue>('membership_checkout_url');
      return mapMembershipCheckoutUrl(raw);
    },
    openExternalUrl: (url) => invoke<void>('open_external_url', { url }),
    openUpdateUrl: (url) => invoke<void>('open_update_url', { url }),
    // P10 — daemon-side restore hook; callers re-fetch status afterwards.
    membershipRestore: async () => {
      await invoke<RawJsonValue>('membership_restore');
    },
    // P09 — local version info
    appVersionInfo: async () => {
      const raw = await invoke<RawJsonValue>('app_version_info');
      return mapAppVersionInfo(raw);
    },
    updateStatus: async () => {
      const raw = await invoke<RawJsonValue>('update_status');
      return decodeLinuxUpdateStatus(raw);
    },
    // P09 — redacted diagnostics export → file path
    exportDiagnostics: async () => {
      const raw = await invoke<RawJsonValue>('export_diagnostics');
      return mapDiagnosticsExport(raw);
    },
    // P11 — session env for pet tier detection
    sessionEnv: async () => {
      const raw = await invoke<RawJsonValue>('session_env');
      return {
        XDG_SESSION_TYPE: str(pick(raw, 'xdg_session_type', 'XDG_SESSION_TYPE')) || undefined,
        XDG_CURRENT_DESKTOP: str(pick(raw, 'xdg_current_desktop', 'XDG_CURRENT_DESKTOP')) || undefined
      };
    },
    // P12 — explicit capability-absent until a real BurnBarRPCMethod media contract exists.
    mediaStatus: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_status');
        return mapMercuryMediaStatus(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { capabilityAvailable: false, pairedDevices: [] };
        }
        throw e;
      }
    },
    mediaSessionState: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_session_state');
        return mapMercurySessionState(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { phase: 'capability-absent', kind: 'call', capabilityAvailable: false };
        }
        throw e;
      }
    },
    mediaAcceptCall: async (requestId) => {
      try {
        const raw = await invoke<RawJsonValue>('media_accept_call', { requestId });
        return mapMercurySessionState(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { phase: 'capability-absent', requestId, kind: 'call', capabilityAvailable: false };
        }
        throw e;
      }
    },
    mediaDeclineCall: async (requestId) => {
      try {
        const raw = await invoke<RawJsonValue>('media_decline_call', { requestId });
        return mapMercurySessionState(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { phase: 'capability-absent', requestId, kind: 'call', capabilityAvailable: false };
        }
        throw e;
      }
    },
    mediaEndCall: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_end_call');
        return mapMercurySessionState(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { phase: 'capability-absent', kind: 'call', capabilityAvailable: false };
        }
        throw e;
      }
    },
    mediaCapabilityGet: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_capability_get');
        return mapMercuryCapability(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            available: false,
            renderer: 'unknown',
            canReceiveCalls: false,
            canViewScreenShare: false,
            reason: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    mediaFileOfferList: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_file_offer_list');
        return mapMercuryFileOfferList(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            capabilityAvailable: false,
            transfers: [],
            detail: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    mediaFileAccept: async ({ transferID, manifestID }) => {
      try {
        const raw = await invoke<RawJsonValue>('media_file_accept', { transferId: transferID, manifestId: manifestID });
        return mapMercuryFileAction(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            accepted: false,
            errorCode: 'capabilityAbsent',
            detail: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    mediaFileDecline: async ({ transferID, manifestID, reason }) => {
      try {
        const raw = await invoke<RawJsonValue>('media_file_decline', {
          transferId: transferID,
          manifestId: manifestID,
          reason
        });
        return mapMercuryFileAction(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            accepted: false,
            errorCode: 'capabilityAbsent',
            detail: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    mediaFileSend: async ({ path, peerID }) => {
      try {
        const raw = await invoke<RawJsonValue>('media_file_send', { path, peerId: peerID });
        return mapMercuryFileAction(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            accepted: false,
            errorCode: 'capabilityAbsent',
            detail: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    toolApprovalRespond: async (approvalId, decision, note) => {
      await invoke<RawJsonValue>('tool_approval_respond', {
        approvalId,
        decision,
        note: note ?? null
      });
    },
    memorySetStatus: (action, payload) =>
      invoke<RawJsonValue>('memory_set_status', { action, payload }),
    computerUseSessionAuthorityStatus: () =>
      invoke<ComputerUseSessionAuthorityStatus>('computer_use_session_authority_status'),
    computerUseSessionStart: (params) =>
      invoke<ComputerUseSessionAuthorityStatus>('computer_use_session_start', { params }),
    computerUseInvoke: async (params) =>
      decodeComputerUseInvokeResponse(await invoke<RawJsonValue>('computer_use_invoke', { params })),
    computerUseApprovalPending: (params) =>
      invoke<RawJsonValue>('computer_use_approval_pending', { params: params ?? null }),
    computerUseApprovalRespond: (params) =>
      invoke<RawJsonValue>('computer_use_approval_respond', { params }),
    computerUseAuditExport: (params) =>
      invoke<RawJsonValue>('computer_use_audit_export', { params: params ?? null }),
    computerUsePanicHalt: async (params) => {
      const sessionId = params?.sessionId ?? '*';
      const source = params?.source ?? 'hotkey';
      const raw = await invoke<RawJsonValue>('computer_use_panic_halt', { sessionId, source });
      return mapComputerUsePanicHalt(raw, source);
    },
    // P13 — daemon-reported smart-display/device integration status.
    integrationsStatus: async () => {
      const raw = await invoke<RawJsonValue>('integrations_status');
      return mapIntegrationsStatus(raw);
    },
    // P28 — fixed-argv SmartHub/device CLI operations; never a generic shell.
    smartHubCommand: async (operation, options) => {
      const payload = options?.requestId ? { operation, requestId: options.requestId } : { operation };
      const raw = await invoke<RawJsonValue>('smarthub_command', payload);
      return decodeSmartHubCommandResponse(raw);
    },
    smartHubCancel: async (requestId) => {
      await invoke<void>('smarthub_cancel', { requestId });
    }
  };
}
