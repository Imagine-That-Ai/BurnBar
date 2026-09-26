/** Daemon Unix-socket RPC envelope. Source of truth for BurnBarRPCContracts. */
namespace OpenBurnBar.Daemon.RPC;

model RpcEnvelope {
  protocolVersion: int32;
  method: string;
  requestId: string;
  payloadJson?: string;
}

model RpcNegotiateRequest {
  clientSupportedVersions: int32[];
}

model RpcNegotiateResponse {
  selectedVersion: int32;
}

/** v1 remains in `supported` for N-1. v2 is current. */
enum RpcProtocolVersion {
  v1: 1,
  v2: 2,
}

/** Daemon RPC method catalog. Adding a method is a member edit here:
    generate.mjs emits the Swift enum + TS union, and the IPC canon derives
    from this file. Wire ids are append-only (see fixtures/daemon-rpc-methods.snapshot.json). */
enum RpcMethod {
  authBootstrap: "auth.bootstrap",
  linuxAuthStatus: "daemon.auth.status",
  linuxAuthBegin: "daemon.auth.begin",
  linuxAuthCancel: "daemon.auth.cancel",
  linuxAuthRotateIdentity: "daemon.auth.rotate_identity",
  linuxAuthSignOut: "daemon.auth.sign_out",
  linuxAccountCloudDataExport: "daemon.account.cloud_data.export",
  linuxAccountCloudDataDelete: "daemon.account.cloud_data.delete",
  /// Trusted-device lifecycle remains daemon-owned. Linux never fabricates
  /// trust state or signs a high-risk mutation; the daemon forwards these
  /// calls only through an injected trusted-device bridge.
  linuxTrustedDeviceList: "daemon.account.trusted_devices.list",
  linuxTrustedDeviceApprove: "daemon.account.trusted_device.approve",
  linuxTrustedDeviceRevoke: "daemon.account.trusted_device.revoke",
  linuxCloudSyncStatus: "daemon.cloud_sync.status",
  linuxCloudSyncPolicyUpdate: "daemon.cloud_sync.policy.update",
  linuxCloudSyncRun: "daemon.cloud_sync.run",
  health: "daemon.health",
  catalog: "daemon.catalog",
  linuxOnboardingSnapshot: "daemon.onboarding.snapshot",
  linuxOnboardingAction: "daemon.onboarding.action",
  linuxOnboardingReset: "daemon.onboarding.reset",
  configGet: "daemon.config.get",
  configUpdate: "daemon.config.update",
  textExpansionGet: "daemon.text_expansion.get",
  textExpansionUpsert: "daemon.text_expansion.upsert",
  textExpansionDelete: "daemon.text_expansion.delete",
  textExpansionConsentUpdate: "daemon.text_expansion.consent.update",
  linuxPrivacyInventory: "daemon.privacy.inventory",
  linuxPrivacyDeletionPreview: "daemon.privacy.deletion.preview",
  linuxPrivacyDeletionExecute: "daemon.privacy.deletion.execute",
  linuxPrivacyExport: "daemon.privacy.export",
  linuxPrivacyRetentionStatus: "daemon.privacy.retention.status",
  linuxPrivacyRetentionApply: "daemon.privacy.retention.apply",
  textExpansionEngineStatus: "daemon.text_expansion.engine.status",
  textExpansionEngineStart: "daemon.text_expansion.engine.start",
  textExpansionEngineStop: "daemon.text_expansion.engine.stop",
  textExpansionEngineExpand: "daemon.text_expansion.engine.expand",
  providerCredentialSlotUpsert: "daemon.provider.credential_slot.upsert",
  providerCredentialSlotRemove: "daemon.provider.credential_slot.remove",
  providerModelVariantUpsert: "daemon.provider.model_variant.upsert",
  providerModelVariantRemove: "daemon.provider.model_variant.remove",
  providerModelAliasUpsert: "daemon.provider.model_alias.upsert",
  providerModelAliasRemove: "daemon.provider.model_alias.remove",
  providerCustomModelUpsert: "daemon.provider.custom_model.upsert",
  providerCustomModelRemove: "daemon.provider.custom_model.remove",
  providerModelDisplayNameSet: "daemon.provider.model_display_name.set",
  providerModelDisplayNameClear: "daemon.provider.model_display_name.clear",
  usageRecord: "daemon.usage.record",
  usageRecent: "daemon.usage.recent",
  usageProjection: "daemon.usage.projection",
  usageRecount: "daemon.usage.recount",
  usageHistory: "daemon.usage.history",
  usageInsights: "daemon.usage.insights",
  chatThreadList: "daemon.chat.thread.list",
  chatThreadGet: "daemon.chat.thread.get",
  chatMessageAppend: "daemon.chat.message.append",
  /// Wave 2.1: pre-mint an empty thread row (pane/thread-lifecycle UX mints
  /// IDs before the first send). Idempotent `INSERT OR IGNORE` semantics so
  /// retries are safe. v1 amendment 2026-09-23, see ADR-005.
  chatThreadCreate: "daemon.chat.thread.create",
  proxyRouteLogRecent: "daemon.proxy.route_log.recent",
  proxyRouteLogClear: "daemon.proxy.route_log.clear",
  quotaSignalsRecent: "daemon.quota.signals.recent",
  quotaSignalsClear: "daemon.quota.signals.clear",
  perfMeasure: "perf.measure",
  membershipStatus: "daemon.membership.status",
  membershipCheckoutURL: "daemon.membership.checkoutUrl",
  membershipPortalURL: "daemon.membership.portalUrl",
  membershipRestore: "daemon.membership.restore",
  connectorPlaneGet: "daemon.connector.plane.get",
  connectorConfigUpdate: "daemon.connector.config.update",
  connectorAction: "daemon.connector.action",
  browserToolingGet: "daemon.browser.tooling.get",
  browserToolingUpdate: "daemon.browser.tooling.update",
  browserAction: "daemon.browser.action",
  computerUseCapabilityStateUpdate: "daemon.computer_use.capability_state.update",
  computerUseSessionGrantReadiness: "daemon.computer_use.session_grant.readiness",
  computerUseSessionGrantAcquire: "daemon.computer_use.session_grant.acquire",
  computerUseSessionGrantStatus: "daemon.computer_use.session_grant.status",
  computerUseSessionStart: "daemon.computer_use.session.start",
  computerUseInvoke: "daemon.computer_use.invoke",
  computerUseApprovalPending: "daemon.computer_use.approval.pending",
  computerUseApprovalRespond: "daemon.computer_use.approval.respond",
  computerUsePanicHalt: "daemon.computer_use.panic_halt",
  computerUseAuditExport: "daemon.computer_use.audit_export",
  /// T-DMN-04: provision the daemon's pinned phone-control verifying key for a
  /// source device. First-party Mac app only; mutates daemon keychain trust state.
  phoneControlPinProvision: "daemon.phone_control.pin.provision",
  daemonMediaSessionState: "daemon.media.session.state",
  daemonMediaCallAccept: "daemon.media.call.accept",
  daemonMediaCallDecline: "daemon.media.call.decline",
  daemonMediaCallEnd: "daemon.media.call.end",
  daemonMediaCapabilityGet: "daemon.media.capability.get",
  daemonMediaStatus: "daemon.media.status",
  daemonMediaFileOfferList: "daemon.media.file.offer.list",
  daemonMediaFileAccept: "daemon.media.file.accept",
  daemonMediaFileDecline: "daemon.media.file.decline",
  daemonMediaFileSend: "daemon.media.file.send",
  controllerSummary: "daemon.controller.summary",
  /// Aggregated controller runtime (summary + questions + followups +
  /// missions + notification health + simulator runs) in one round trip.
  /// Newer than the per-list RPCs: clients must fall back to those when
  /// an older daemon rejects this method.
  controllerRuntimeSnapshot: "daemon.controller.runtime_snapshot",
  controllerProjectsList: "daemon.controller.project.list",
  controllerProjectGet: "daemon.controller.project.get",
  controllerProjectUpsert: "daemon.controller.project.upsert",
  controllerProjectDelete: "daemon.controller.project.delete",
  controllerProjectReassign: "daemon.controller.project.reassign",
  reviewRunRecord: "daemon.controller.review.record",
  questionCreate: "daemon.question.create",
  questionGet: "daemon.question.get",
  questionsList: "daemon.question.list",
  questionAnswer: "daemon.question.answer",
  followupCreate: "daemon.followup.create",
  followupsList: "daemon.followup.list",
  followupDone: "daemon.followup.done",
  followupSnooze: "daemon.followup.snooze",
  followupCalendar: "daemon.followup.calendar",
  missionCreate: "daemon.mission.create",
  missionsList: "daemon.mission.list",
  missionGet: "daemon.mission.get",
  missionHealth: "daemon.mission.health",
  missionApprove: "daemon.mission.approve",
  missionCancel: "daemon.mission.cancel",
  missionDispatchPacket: "daemon.mission.packet.dispatch",
  missionRecordResult: "daemon.mission.result.record",
  /// M2 (split-brain remediation Phase 2): daemon-side authorization verdict
  /// for a remote (mobile/Wand) mission whose sealed payload the GUI
  /// transport has already unsealed and decoded. Additive — no shipped
  /// client calls it yet; M3 wires the GUI listener in shadow mode.
  missionAuthorizeRemote: "daemon.mission.authorizeRemote",
  notificationConfigGet: "daemon.notification.config.get",
  notificationConfigUpdate: "daemon.notification.config.update",
  notificationHealth: "daemon.notification.health",
  notificationCommand: "daemon.notification.command",
  simulatorRun: "daemon.simulator.run",
  simulatorList: "daemon.simulator.list",
  simulatorReplay: "daemon.simulator.replay",
  projectionRebuild: "daemon.projection.rebuild",
  runCreate: "run.create",
  runList: "run.list",
  runGet: "run.get",
  runPoll: "run.poll",
  runCancel: "run.cancel",
  runRetry: "run.retry",
  workspaceExecuteTool: "workspace.executeTool",
  workspaceToolResult: "workspace.toolResult",
  approvalRespond: "approval.respond",
  subscriptionStart: "subscription.start",
  subscriptionResume: "subscription.resume",
  subscriptionStop: "subscription.stop",
  clientAttach: "client.attach",
  clientClaimControl: "client.claimControl",
  clientDetach: "client.detach",
  /// Planner-backed lexical + aggregate search over the local OpenBurnBar SQLite index (daemon must have DB path).
  searchQuery: "daemon.search.query",
  /// Single read-only SELECT over the shared indexed store, executed on the daemon's
  /// keyed handle so socket clients (local MCP) work against the SQLCipher database
  /// without holding the key. Enforced via `sqlite3_stmt_readonly` + row/byte caps.
  searchSQL: "daemon.search.sql",
  /// Wave 2.1c-ii: the app lane of `vector_index_snapshots` moves to the
  /// daemon (single writer, ADR-005). The app finalizes the row; the daemon
  /// validates shape and bounds, then stores it verbatim. v1 amendment
  /// 2026-09-23, see ADR-005.
  searchVectorSnapshotUpsert: "daemon.search.vector_snapshot.upsert",
  /// Wave 2.1c-iv: the app lane of `search_documents` / `search_chunks` /
  /// `search_chunks_fts` moves to the daemon (single writer, ADR-005).
  /// The app finalizes the write set (diffs computed against local reads);
  /// the daemon validates shape and bounds, then stores it verbatim in one
  /// transaction. v1 amendment 2026-09-23, see ADR-005.
  searchIndexApply: "daemon.search.index.apply",
  /// Wave 2.1c-v: the app lane of `switcher_active_profile` moves to the
  /// daemon (single writer, ADR-005). The app finalizes the write (mirror
  /// and fallback lookups computed against local reads); the daemon
  /// validates shape, then applies the sets verbatim in one transaction.
  /// v1 amendment 2026-09-23, see ADR-005.
  switcherActiveProfileApply: "daemon.switcher.active_profile.apply",
  memoryRemember: "daemon.memory.remember",
  memoryRecall: "daemon.memory.recall",
  memoryReviewStatus: "daemon.memory.review_status",
  memoryForget: "daemon.memory.forget",
  memoryAuditTrail: "daemon.memory.audit_trail",
  memoryAnalytics: "daemon.memory.analytics",
  /// Memory Pro: what the memory engine may use (Pro state, consented providers,
  /// models per purpose, CLI consent) plus a scoped loopback-gateway token.
  memoryModelPolicy: "daemon.memory.model_policy",
  /// Memory Blind Sync (PR-2): the engine drains the remote facts the app's
  /// pull lane verified and parked, then acknowledges what it merged. Reading
  /// the inbox is a memory read; the acknowledgement writes `applied_at`.
  memorySyncInboxList: "daemon.memory.sync.inbox.list",
  memorySyncInboxAck: "daemon.memory.sync.inbox.ack",
  /// Wave 2.1c: the app lane of `project_memory_snapshots` moves to the
  /// daemon (single writer, ADR-005). Upsert stores the app-finalized bytes
  /// verbatim; delete drops one slug; delete-all serves the indexed-data
  /// wipe. v1 amendment 2026-09-23, see ADR-005.
  memorySnapshotUpsert: "daemon.memory.snapshot.upsert",
  memorySnapshotDelete: "daemon.memory.snapshot.delete",
  memorySnapshotDeleteAll: "daemon.memory.snapshot.delete_all",
  /// Wave 2.1c-iii: the app lane of the memory authority tables
  /// (`agent_memories`, `memory_audit`, and their satellite rows) moves to
  /// the daemon (single writer, ADR-005). One atomic applier for the app's
  /// finalized write sets; the daemon assigns only the audit chain fields.
  /// v1 amendment 2026-09-23, see ADR-005.
  memoryAuthorityApply: "daemon.memory.authority.apply",
  codeIndexProject: "daemon.code.index_project",
  codeSearch: "daemon.code.search",
  codeContextPack: "daemon.code.context_pack",
  codeGetSymbol: "daemon.code.get_symbol",
  codeFindReferences: "daemon.code.find_references",
  codeCallGraph: "daemon.code.call_graph",
  codeDiagnostics: "daemon.code.diagnostics",
  codeIndexStatus: "daemon.code.index_status",
  codeExplore: "daemon.code.explore",
  codeWatchProject: "daemon.code.watch_project",
  codeOpsDiagnostics: "daemon.code.ops_diagnostics",
  codeDatabaseSnapshot: "daemon.code.database_snapshot",
  codeDatabaseRestore: "daemon.code.database_restore",
  databaseRecoveryStatus: "daemon.database.recovery.status",
  databaseRecoveryBundleExport: "daemon.database.recovery_bundle.export",
  databaseRecoveryBundleImport: "daemon.database.recovery_bundle.import",
  /// AI Inbox — daemon-resident proactive analyst. Reads are observability
  /// shaped; config/run mutations spend money and are classified with config.
  inboxList: "daemon.inbox.list",
  inboxGet: "daemon.inbox.get",
  inboxRunsRecent: "daemon.inbox.runs.recent",
  inboxConfigGet: "daemon.inbox.config.get",
  inboxConfigUpdate: "daemon.inbox.config.update",
  inboxRunNow: "daemon.inbox.run_now",
  /// Founder Lens: fingerprint-keyed reply threads. `thread.get` is a read;
  /// `reply` spends model budget and is config-scoped.
  inboxThreadGet: "daemon.inbox.thread.get",
  inboxReply: "daemon.inbox.reply",
  /// Founder Plan Ledger. Reads observability; accept/update/grade are
  /// human-confirmed mutations, config-scoped.
  inboxPlansList: "daemon.inbox.plans.list",
  inboxPlansGet: "daemon.inbox.plans.get",
  inboxPlansAccept: "daemon.inbox.plans.accept",
  inboxPlansUpdateStep: "daemon.inbox.plans.update_step",
  inboxPlansGrade: "daemon.inbox.plans.grade",
  /// App → daemon push of approved chat-authority snippets (full-set
  /// replacement, so revocations propagate by omission).
  inboxMemoryExport: "daemon.inbox.memory.export",
  runResume: "run.resume",
  /// Live Agent Fleet: observe running agents and send light control.
  fleetSnapshot: "daemon.fleet.snapshot",
  fleetOrchestratorGet: "daemon.fleet.orchestrator.get",
  fleetOrchestratorSet: "daemon.fleet.orchestrator.set",
  fleetDirectiveRecord: "daemon.fleet.directive.record",
  /// War Room, the Flame: ask which machine should run a unit of work, read
  /// the decision history, and report what became of a decision.
  warFlameRoute: "daemon.war.flame.route",
  warFlameDistillList: "daemon.war.flame.distill.list",
  warFlameDistillSettle: "daemon.war.flame.distill.settle",
}
