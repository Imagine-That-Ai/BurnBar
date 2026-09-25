import AppKit
import FirebaseCore
import FirebaseRemoteConfig
import Foundation
import Observation
import OpenBurnBarCore

extension SettingsManager {
    // MARK: Memory (G4: user toggle + Remote Config fleet kill switch)

    /// User toggle: automatic extraction on terminal assistant commit (default ON).
    var memoryAutomaticExtraction: Bool {
        get { memory.automaticExtraction }
        set { memory.automaticExtraction = newValue }
    }

    /// Opt-in sub-toggle: high-recall per-reply (default OFF).
    var memoryHighRecallPerReply: Bool {
        get { memory.highRecallPerReply }
        set { memory.highRecallPerReply = newValue }
    }

    /// User consent to chat-memory extraction (gate G0, default OFF). Setting this
    /// true also marks the consent prompt as shown. Until granted, the whole
    /// memory loop is dormant (see `memoryExtractionEnabled`).
    var memoryConsentGranted: Bool {
        get { memory.consentGranted }
        set { memory.consentGranted = newValue }
    }

    /// Whether the first-run memory consent prompt has already been presented.
    var memoryConsentShown: Bool {
        get { memory.consentShown }
        set { memory.consentShown = newValue }
    }

    /// Remote Config `memory_extraction_enabled`. Not user-settable; written by
    /// successful RC refreshes. Explicit fleet kills set this false; fetch
    /// transport errors still honor an active cached false kill.
    var memoryExtractionRemoteConfigEnabled: Bool {
        get { memory.remoteConfigExtractionEnabled }
        set { memory.remoteConfigExtractionEnabled = newValue }
    }

    /// Combined extraction gate (G0 + G4): user CONSENT **and** the user toggle
    /// **and** the fleet kill switch must all allow. This is the single value the
    /// extraction chokepoint consults; with consent default OFF the whole loop is
    /// dormant out of the box.
    var memoryExtractionEnabled: Bool {
        MemoryExtractionGate.isEnabled(
            consentGranted: memory.consentGranted,
            automaticExtraction: memory.automaticExtraction,
            remoteConfigEnabled: memory.remoteConfigExtractionEnabled
        )
    }

    /// Raw user opt-in to replicate approved sealed memory facts to the cloud
    /// vault (default OFF — PR-E2). This is the persisted toggle only; the value
    /// the cloud-sync scheduler actually consults is `memoryApprovedCloudBackupEnabled`,
    /// which additionally clamps this under the fleet ceiling.
    var memoryApprovedCloudBackupOptIn: Bool {
        get { memory.approvedCloudBackupEnabled }
        set { memory.approvedCloudBackupEnabled = newValue }
    }

    /// Combined cloud-backup gate for derived memory: the explicit user opt-in
    /// AND the Remote Config fleet ceiling (`remoteConfigExtractionEnabled`).
    /// Folding the egress switch under the same fleet kill switch that halts
    /// extraction means one Remote Config flip stops both producing new memory
    /// and shipping existing memory off-device. Default OFF (the opt-in defaults
    /// false), so `MemoryCloudSyncDomain` performs zero egress out of the box.
    var memoryApprovedCloudBackupEnabled: Bool {
        memory.approvedCloudBackupEnabled && memory.remoteConfigExtractionEnabled
    }

    /// Raw user opt-in to the PULL half of memory sync — reading the member's own
    /// sealed facts back down onto this device (default OFF — Memory Blind Sync
    /// PR-2). Persisted toggle only; the scheduler consults
    /// `memoryDeviceSyncEnabled`, which folds this under the backup gate.
    var memoryDeviceSyncOptIn: Bool {
        get { memory.deviceSyncEnabled }
        set { memory.deviceSyncEnabled = newValue }
    }

    /// The EFFECTIVE gate for the pull half (`MemoryDeviceSyncGate`): the
    /// device-sync sub-toggle AND the backup opt-in AND the live Data Vault
    /// entitlement AND the Remote Config fleet ceiling. Default OFF. Turning
    /// cloud backup off stops downloads too — a member who revokes memory
    /// egress does not keep an active memory sync channel — and a lapsed or
    /// not-yet-resolved entitlement closes it as well.
    ///
    /// The entitlement lever is here, and not merely on the row, because
    /// `firestore.rules` gates `memory_facts` **writes** on
    /// `hasActiveDataVaultEntitlement(userId)` while **reads** are granted by
    /// the per-user namespace rule with no entitlement check. This client gate
    /// is what keeps an unentitled install from issuing a live `memory_facts`
    /// read at all.
    var memoryDeviceSyncEnabled: Bool {
        MemoryDeviceSyncGate.isEnabled(
            deviceSyncOptIn: memory.deviceSyncEnabled,
            backupOptIn: memory.approvedCloudBackupEnabled,
            entitlementSatisfied: memory.deviceSyncEntitlementSatisfied,
            remoteConfigEnabled: memory.remoteConfigExtractionEnabled
        )
    }

    /// Live Data Vault entitlement check for the device-sync gate (default
    /// OFF — fail closed, not persisted). Refreshed from
    /// `MacCloudEntitlementStore` by the Privacy & Indexing view as the
    /// member's resolved tier changes, and by `MemoryCloudSyncDomain` on every
    /// sync cycle so the pull's gate never depends on Settings having been
    /// opened. See `MemorySettings.deviceSyncEntitlementSatisfied`.
    var memoryDeviceSyncEntitlementSatisfied: Bool {
        get { memory.deviceSyncEntitlementSatisfied }
        set { memory.deviceSyncEntitlementSatisfied = newValue }
    }

    /// Whether the device-sync row can be interacted with at all: the backup
    /// gate (opt-in AND fleet ceiling) AND the Data Vault entitlement.
    /// Deliberately excludes the sub-toggle itself — a member who has satisfied
    /// every other lever must still be free to flip the sub-toggle on or off.
    var memoryDeviceSyncRowUnlocked: Bool {
        memoryApprovedCloudBackupEnabled && memory.deviceSyncEntitlementSatisfied
    }

    /// What the "Sync memories to my other devices" row displays. Identical to
    /// `memoryDeviceSyncEnabled` by construction: the row shows exactly the
    /// gate the pull obeys, so a greyed-out switch never reads "on" and an
    /// on-looking switch never corresponds to a dormant channel.
    var memoryDeviceSyncRowEnabled: Bool { memoryDeviceSyncEnabled }

    // MARK: Team memory (memory program D16)

    /// The teams the member has opted into sharing memory with (default EMPTY).
    /// The scheduler ANDs this per team with the whole device-sync gate through
    /// `TeamMemorySyncGate`, so this set alone can never start a team upload.
    var memoryTeamSyncEnabledTeamIDs: Set<String> {
        get { memory.teamMemorySyncEnabled }
        set { memory.teamMemorySyncEnabled = newValue }
    }

    /// The team lane's fleet ceiling and its resolution state. See
    /// `MemorySettings.applyTeamRemoteConfig`.
    var memoryTeamSyncRemoteConfigAllowed: Bool { memory.remoteConfigTeamSyncEnabled }
    var memoryTeamSyncRemoteConfigResolved: Bool { memory.hasResolvedTeamRemoteConfig }

    /// Apply a resolved Remote Config value to the team fleet ceiling and open
    /// it for gating. The only path that resolves it, mirroring
    /// `applyUsageMemoryRemoteConfig`; called from `refreshComputerUseRemoteConfigOnce`
    /// on both the cached and the fetched beat. Resolution alone opens nothing:
    /// `TeamMemorySyncGate` still needs the personal gate, the account levers,
    /// a per-team opt-in and an active roster row.
    ///
    /// WHAT RESOLUTION ACTUALLY PROVES. The cached beat reads whatever
    /// `RemoteConfig` has, which on an install that has never completed a fetch
    /// is the REGISTERED DEFAULT — so "resolved" means "a value was applied",
    /// not "a fleet value was observed", and an offline install resolves to the
    /// default rather than staying held closed. This matches the usage lanes'
    /// precedent exactly and is harmless while the opt-in set is empty (nothing
    /// can run without a per-team opt-in, and no UI mints one before PR 4). PR 4
    /// lands that UI: if the ceiling must be a POSITIVE fleet observation before
    /// a member can opt in, register the default `false` and let the fetched
    /// beat be the only thing that opens it.
    func applyTeamMemoryRemoteConfig(teamSyncEnabled: Bool) {
        memory.applyTeamRemoteConfig(teamSyncEnabled: teamSyncEnabled)
    }

    // MARK: Memory Pro cloud models (opt-in, blind)

    /// Raw user opt-in to cloud / big models for memory (default OFF). The
    /// value the daemon actually receives is `memoryCloudModelsEnabled`.
    var memoryCloudModelsOptIn: Bool {
        get { memory.cloudModelsEnabled }
        set { memory.cloudModelsEnabled = newValue }
    }

    var memoryCloudModelsConsentShown: Bool {
        get { memory.cloudModelsConsentShown }
        set { memory.cloudModelsConsentShown = newValue }
    }

    var memoryCloudModelsRequireNoRetention: Bool {
        get { memory.cloudModelsRequireNoRetention }
        set { memory.cloudModelsRequireNoRetention = newValue }
    }

    var memoryCloudModelsDailyCapUSD: Double {
        get { memory.cloudModelsDailyCapUSD }
        set { memory.cloudModelsDailyCapUSD = newValue }
    }

    var memoryCloudModelsConsentedProviders: [MemoryCloudProviderID] {
        get { memory.cloudModelsConsentedProviderIDs }
        set { memory.cloudModelsConsentedProviderIDs = newValue }
    }

    /// Remote Config `memory_cloud_models_enabled`. Not user-settable; written
    /// by RC refreshes with the same posture as `memoryExtractionRemoteConfigEnabled`.
    var memoryCloudModelsRemoteConfigEnabled: Bool {
        get { memory.remoteConfigCloudModelsEnabled }
        set { memory.remoteConfigCloudModelsEnabled = newValue }
    }

    /// Combined cloud-models gate: memory consent **and** the cloud-models
    /// toggle **and** the fleet switch. This is what the daemon policy carries.
    var memoryCloudModelsEnabled: Bool {
        MemoryCloudModelsGate.isEnabled(
            consentGranted: memory.consentGranted,
            cloudModelsEnabled: memory.cloudModelsEnabled,
            remoteConfigEnabled: memory.remoteConfigCloudModelsEnabled
        )
    }

    /// The daemon's memory egress policy as implied by these settings. CLI
    /// providers are included only while Mac CLI agents are allowed too; API
    /// providers map to daemon provider ids. Disabling keeps the provider list
    /// so re-enabling restores the member's choice.
    func memoryEgressPolicy(now: Date = Date()) -> BurnBarMemoryEgressPolicy {
        // "No retention only" is a promise about every route, and the daemon can
        // only enforce it for API providers; subscription CLIs (`localQuota`) and
        // provider-policy APIs are therefore left out of the policy entirely
        // while it is on, instead of being sent and trusted.
        let noRetentionOnly = memory.cloudModelsRequireNoRetention
        let consented = memory.cloudModelsConsentedProviderIDs
            .filter { !noRetentionOnly || $0.retention == .deny }
        var policy = BurnBarMemoryEgressPolicy()
        policy.enabled = memoryCloudModelsEnabled
        policy.consentedProviderIDs = consented.compactMap(\.daemonProviderID)
        policy.consentedCLIProviderIDs = cliAssistantAllowed
            ? consented.filter(\.requiresCLIConsent).map(\.rawValue)
            : []
        policy.allowedModelIDsByPurpose = [:]
        policy.requireNoRetention = memory.cloudModelsRequireNoRetention
        policy.dailyCapUSD = memory.cloudModelsDailyCapUSD
        policy.updatedAt = now
        return policy
    }

    // MARK: Activation Checklist

    /// The user closed the activation checklist by hand; it never returns.
    var activationChecklistDismissed: Bool {
        get { activation.checklistDismissed }
        set { activation.checklistDismissed = newValue }
    }

    /// When every activation step first read as done. Non-nil retires the card.
    var activationChecklistCompletedAt: Date? {
        get { activation.checklistCompletedAt }
        set { activation.checklistCompletedAt = newValue }
    }

    // MARK: Usage Memory (passive memory from Safari asks + agent session logs)

    /// User consent to usage-memory extraction (default OFF). Setting this true
    /// also marks the consent prompt as shown. Until granted, the whole usage
    /// loop is dormant (see `usageMemoryExtractionEnabled`).
    var usageMemoryConsentGranted: Bool {
        get { memory.usageMemoryConsentGranted }
        set { memory.usageMemoryConsentGranted = newValue }
    }

    /// Whether the usage-memory consent prompt has already been presented.
    var usageMemoryConsentShown: Bool {
        get { memory.usageMemoryConsentShown }
        set { memory.usageMemoryConsentShown = newValue }
    }

    /// Separate opt-in to CLOUD curation of usage memory (default OFF). Only
    /// effective when the extraction gate is open AND placement is a cloud model
    /// (see `usageMemoryCloudCurationEnabled`).
    var usageMemoryCloudCurationConsentGranted: Bool {
        get { memory.usageMemoryCloudCurationConsentGranted }
        set { memory.usageMemoryCloudCurationConsentGranted = newValue }
    }

    /// Where the usage-memory curation model runs (default `.local`).
    var usageMemoryModelPlacement: UsageMemoryModelPlacement {
        get { memory.usageMemoryModelPlacement }
        set { memory.usageMemoryModelPlacement = newValue }
    }

    /// Source toggle: Safari asks feed usage memory (default ON, inert until consent).
    var usageMemorySourceSafariAsksEnabled: Bool {
        get { memory.usageMemorySourceSafariAsksEnabled }
        set { memory.usageMemorySourceSafariAsksEnabled = newValue }
    }

    /// Source toggle: agent session logs feed usage memory (default ON, inert until consent).
    var usageMemorySourceAgentSessionsEnabled: Bool {
        get { memory.usageMemorySourceAgentSessionsEnabled }
        set { memory.usageMemorySourceAgentSessionsEnabled = newValue }
    }

    /// Remote Config `memory_usage_extraction_enabled`. Not user-settable;
    /// written by RC refreshes with the same fail-open-on-transport posture as
    /// `memoryExtractionRemoteConfigEnabled`. Writing this alone does NOT resolve
    /// the lanes — only `applyUsageMemoryRemoteConfig` does — so a stray `true`
    /// here can never open a lane on its own.
    var usageMemoryExtractionRemoteConfigEnabled: Bool {
        get { memory.remoteConfigUsageExtractionEnabled }
        set { memory.remoteConfigUsageExtractionEnabled = newValue }
    }

    /// Remote Config `memory_usage_authority_writes_enabled`. Not user-settable;
    /// written by RC refreshes with the same fail-open-on-transport posture, and
    /// with the same "writing it does not resolve the lanes" rule as above.
    var usageMemoryAuthorityWritesRemoteConfigEnabled: Bool {
        get { memory.remoteConfigUsageAuthorityWritesEnabled }
        set { memory.remoteConfigUsageAuthorityWritesEnabled = newValue }
    }

    /// Whether a Remote Config value (cached or fetched) has been applied to the
    /// usage fleet switches. Both usage lanes stay CLOSED until this is true.
    var usageMemoryRemoteConfigResolved: Bool { memory.hasResolvedUsageRemoteConfig }

    /// Apply a resolved Remote Config snapshot to both usage fleet switches at
    /// once and open the lanes for gating. The only path that resolves them.
    func applyUsageMemoryRemoteConfig(extractionEnabled: Bool, authorityWritesEnabled: Bool) {
        memory.applyUsageRemoteConfig(
            extractionEnabled: extractionEnabled,
            authorityWritesEnabled: authorityWritesEnabled
        )
    }

    /// Combined usage-memory extraction gate: user consent AND the fleet kill
    /// switch AND that fleet value having been resolved. With consent default OFF
    /// the whole usage loop is dormant out of the box, and it stays dormant
    /// through the startup window before Remote Config is read.
    var usageMemoryExtractionEnabled: Bool {
        UsageMemoryExtractionGate.isEnabled(
            usageConsentGranted: memory.usageMemoryConsentGranted,
            remoteConfigEnabled: memory.remoteConfigUsageExtractionEnabled,
            remoteConfigResolved: memory.hasResolvedUsageRemoteConfig
        )
    }

    /// Combined usage-memory authority-write gate: the dedicated fleet switch AND
    /// resolution. Independent of consent and of the extraction gate — this is the
    /// value mirrored into the registry's authority-writes lane.
    var usageMemoryAuthorityWritesEnabled: Bool {
        UsageMemoryAuthorityWriteGate.isEnabled(
            remoteConfigEnabled: memory.remoteConfigUsageAuthorityWritesEnabled,
            remoteConfigResolved: memory.hasResolvedUsageRemoteConfig
        )
    }

    /// Combined cloud-curation gate for usage memory: the extraction gate AND
    /// the separate cloud consent AND a cloud model placement. Triply dormant by
    /// default (no consent, no cloud consent, placement `.local`), so there is
    /// zero usage-derived cloud egress out of the box.
    var usageMemoryCloudCurationEnabled: Bool {
        UsageMemoryCloudGate.isEnabled(
            extractionEnabled: usageMemoryExtractionEnabled,
            cloudConsentGranted: memory.usageMemoryCloudCurationConsentGranted,
            placementIsCloud: memory.usageMemoryModelPlacement.isCloud
        )
    }

    // MARK: Chat Backend
    var openClawGatewayBaseURL: String {
        get { chatBackend.openClawGatewayBaseURL }
        set { chatBackend.openClawGatewayBaseURL = newValue }
    }

    var openClawBearerToken: String {
        get { chatBackend.openClawBearerToken }
        set { chatBackend.openClawBearerToken = newValue }
    }

    var hermesBearerToken: String {
        get { chatBackend.hermesBearerToken }
        set { chatBackend.hermesBearerToken = newValue }
    }

    var hermesChatModelOverride: String {
        get { chatBackend.hermesChatModelOverride }
        set { chatBackend.hermesChatModelOverride = newValue }
    }

    var hermesGatewayBaseURL: String {
        get { chatBackend.hermesGatewayBaseURL }
        set { chatBackend.hermesGatewayBaseURL = newValue }
    }

    var hermesRemoteRelayEnabled: Bool {
        get { chatBackend.hermesRemoteRelayEnabled }
        set { chatBackend.hermesRemoteRelayEnabled = newValue }
    }

    var hermesRealtimeRelayURL: String {
        get { chatBackend.hermesRealtimeRelayURL }
        set { chatBackend.hermesRealtimeRelayURL = newValue }
    }

    var hermesIrohTransportEnabled: Bool {
        get { chatBackend.hermesIrohTransportEnabled }
        set { chatBackend.hermesIrohTransportEnabled = newValue }
    }

    /// Mercury Phase 1 — see `ChatBackendSettings.mediaBlobTransferEnabled`.
    var mediaBlobTransferEnabled: Bool {
        get { chatBackend.mediaBlobTransferEnabled }
        set { chatBackend.mediaBlobTransferEnabled = newValue }
    }

    var computerUseWatchEnabled: Bool {
        get { chatBackend.computerUseWatchEnabled }
        set { chatBackend.computerUseWatchEnabled = newValue }
    }

    var computerUseBrowserEnabled: Bool {
        get { chatBackend.computerUseBrowserEnabled }
        set { chatBackend.computerUseBrowserEnabled = newValue }
    }

    var computerUseSystemEnabled: Bool {
        get { chatBackend.computerUseSystemEnabled }
        set { chatBackend.computerUseSystemEnabled = newValue }
    }

    var computerUsePhoneControlEnabled: Bool {
        get { chatBackend.computerUsePhoneControlEnabled }
        set { chatBackend.computerUsePhoneControlEnabled = newValue }
    }

    var computerUsePhoneControlAttestationRequired: Bool {
        get { chatBackend.computerUsePhoneControlAttestationRequired }
        set { updateComputerUsePhoneControlAttestationRequired(newValue) }
    }

    private func updateComputerUsePhoneControlAttestationRequired(_ required: Bool) {
        let previous = chatBackend.computerUsePhoneControlAttestationRequired
        chatBackend.computerUsePhoneControlAttestationRequired = required
        guard previous != required else { return }
        NotificationCenter.default.post(
            name: .phoneControlAttestationDidChange,
            object: self,
            userInfo: [
                ComputerUseRemoteConfigNotificationUserInfo.phoneControlAttestationRequired: required
            ]
        )
    }

    var computerUseTrustedScopesEnabled: Bool {
        get { chatBackend.computerUseTrustedScopesEnabled }
        set { chatBackend.computerUseTrustedScopesEnabled = newValue }
    }

    var computerUseAuditExportEnabled: Bool {
        get { chatBackend.computerUseAuditExportEnabled }
        set { chatBackend.computerUseAuditExportEnabled = newValue }
    }

    var computerUseKillSwitch: Bool {
        get { chatBackend.computerUseKillSwitch }
        set { chatBackend.computerUseKillSwitch = newValue }
    }

    var computerUsePhoneControlRespectsDenyRegions: Bool {
        get { chatBackend.computerUsePhoneControlRespectsDenyRegions }
        set { chatBackend.computerUsePhoneControlRespectsDenyRegions = newValue }
    }

    var mediaKillSwitch: Bool {
        get { chatBackend.mediaKillSwitch }
        set { chatBackend.mediaKillSwitch = newValue }
    }

    /// War Room's global stop (the Wire + the Flame). Fail-closed: engaged
    /// unless Remote Config says otherwise, so an unreachable config never
    /// opens the Mac⇄Mac lane.
    var warRoomKillSwitch: Bool {
        get { chatBackend.warRoomKillSwitch }
        set { chatBackend.warRoomKillSwitch = newValue }
    }

    /// Which machine the Hermes Room points at. Nil means this Mac.
    var activeHermesBodyID: String? {
        get { chatBackend.activeHermesBodyID.isEmpty ? nil : chatBackend.activeHermesBodyID }
        set { chatBackend.activeHermesBodyID = newValue ?? "" }
    }

    var launchHermesWithOpenBurnBar: Bool {
        get { chatBackend.launchHermesWithOpenBurnBar }
        set { chatBackend.launchHermesWithOpenBurnBar = newValue }
    }
}
