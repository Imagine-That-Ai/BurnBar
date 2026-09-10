import OpenBurnBarKernel
import SwiftUI

// MARK: - Memory Sync

/// The one place memory sync lives.
///
/// Before this pane, every memory-sync control sat inside the *Indexing &
/// Search* page under the General tab — three levels below a row whose subtitle
/// read "Local index, embeddings, cross-encoder reranking". A member looking for
/// sync opened **Devices & Sync**, found a section literally headed "Sync"
/// holding exactly one row (Cloud sync), and concluded memory sync did not
/// exist. It did; it was just filed under the wrong noun.
///
/// So the controls moved here, and this pane is now the single implementation.
/// Both entry points — Devices & Sync → Sync → "Memory Sync" and Search &
/// Memory → Memory → "Memory Sync" — push *this* view, rather than rendering a
/// second copy that could drift from it.
enum MemorySyncCopy {

    /// The pane's own title, and the label of both rows that lead to it. One
    /// constant so the row a member clicks and the screen they land on can
    /// never disagree.
    static let title = "Memory Sync"

    /// The row subtitle in both entry points. Names both halves, because both
    /// halves ship: the push (backup) landed in Memory Blind Sync PR 1, and the
    /// pull plus the engine merge landed in PR 2 (#2519).
    static let rowSubtitle =
        "Back up approved memories, and pull them back down onto your other signed-in devices"

    /// The honest one-liner at the top of the pane.
    ///
    /// Every clause is a claim this repo can back:
    ///   * "sealed on this Mac" — `CloudVaultCrypto` seals `sealedMemory` with a
    ///     Keychain-held key; `firestore.rules`' `validMemoryFactKeys()` rejects
    ///     a document carrying `text`, `body`, `citations`, or any vector.
    ///   * "approved" — the rules require `reviewStatus == "approved"`; nothing
    ///     awaiting review can be written at all.
    ///   * "arrive on your other signed-in devices" — the pull half and the
    ///     engine merge are on `main` (`MemoryCloudPullService`,
    ///     `daemon.memory.sync.inbox.list` / `.ack`), so this is a statement
    ///     about today rather than a roadmap.
    static let summary =
        "Off by default. Memories you have approved are sealed on this Mac before they leave it, "
        + "and — with both switches on — arrive on your other signed-in devices and merge into "
        + "their memory. BurnBar holds no key and cannot read any of it."

    /// The boundary that surprises people, stated where they will meet it.
    /// A project's identity is derived from its git origin and root commit; a
    /// non-git folder falls back to a local path fingerprint, which differs on
    /// every machine, so its memories travel but never converge.
    static let gitBoundaryNote =
        "Memories learned in a git repository merge across your devices, because a repo has the "
        + "same identity everywhere. Memories from a folder that is not a git repository still "
        + "travel and still arrive — they simply land as separate entries, because that folder "
        + "has no identity your other Mac can recognise."

    /// The summary value both drill rows show. Reads the EFFECTIVE gate, not the
    /// raw sub-toggle, so a row can never say "On" while the pull is closed by
    /// the entitlement, the backup opt-in, or the fleet ceiling.
    @MainActor
    static func rowValue(_ settingsManager: SettingsManager) -> String {
        settingsManager.memoryDeviceSyncEnabled ? "On" : "Off"
    }
}

/// Canonical Memory Sync pane. Everything that decides whether a memory leaves
/// this Mac, or arrives on it, is on this one screen: the backup opt-in, the
/// device-sync sub-toggle it gates, team spaces, the health card, and the
/// diagnostic status row.
struct MemorySyncSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    /// Live runtime context. Supplies the shared `ControlPlaneStore` the health
    /// card and the status row read, and the sync domain the team section
    /// invalidates on leave. Optional so callers without a runtime context still
    /// compile; those surfaces then self-hide rather than dead-ending.
    var runtimeContext: OpenBurnBarRuntimeContext?
    var accountManager: AccountManager = .shared

    /// Live Data Vault entitlement (Pro Max or Ultra), the same gate the
    /// cloud-models section unlocks against.
    @ObservedObject private var deviceSyncEntitlement = MacCloudEntitlementStore.shared
    @State private var showDeviceSyncUnlockSheet = false
    @State private var showTeamMemoryUnlockSheet = false
    @State private var teamMemoryModel: TeamMemorySectionModel?
    /// Collapsed by default: the sync-status row answers "why has nothing
    /// arrived", which is a question a member only asks when something looks
    /// wrong. Mirrors the Advanced disclosure in Connections.
    @State private var isMemorySyncStatusExpanded = false

    private static let deviceSyncGatedFeature = GatedFeature.gatedFeature(.dataVault)

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .memorySync) { _ in
            ScrollView {
                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        summaryHeader

                        Divider().background(DesignSystem.Colors.border)

                        SettingsToggle(
                            title: "Back up approved memories",
                            subtitle: "Off by default. When on, only memories you approve are replicated to your cloud vault, end-to-end sealed. Declining keeps every memory on this Mac.",
                            isOn: $settingsManager.memoryApprovedCloudBackupOptIn
                        )
                        .settingsAnchor(SettingsAnchor.memorySyncBackup)

                        deviceSyncRow

                        gitBoundaryFootnote

                        Divider().background(DesignSystem.Colors.border)

                        teamMemorySection

                        memoryHealthSection

                        memorySyncStatusSection
                    }
                    .padding(DesignSystem.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .background(DesignSystem.Colors.background)
        .navigationTitle(MemorySyncCopy.title)
        .onAppear { refreshDeviceSyncEntitlement() }
        .onChange(of: deviceSyncEntitlement.cloudTier) { _, _ in
            refreshDeviceSyncEntitlement()
        }
    }

    // MARK: - Header

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.teal)
                Text(MemorySyncCopy.title)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            Text(MemorySyncCopy.summary)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsAnchor(SettingsAnchor.memorySyncOverview)
    }

    private var gitBoundaryFootnote: some View {
        Text(MemorySyncCopy.gitBoundaryNote)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Device sync

    /// "Sync memories to my other devices". Below the Data Vault tier the row
    /// sits behind `LockedFeatureVeil` with a real unlock path, mirroring
    /// `MemoryCloudModelsSection` — a member who cannot use the feature is shown
    /// what it is and how to get it, not a dead grey switch. The other two
    /// levers (the backup opt-in and the fleet ceiling) keep the plain disabled
    /// + explanatory-subtitle treatment, because those the member can resolve
    /// on this same screen or not at all.
    @ViewBuilder
    private var deviceSyncRow: some View {
        Group {
            if deviceSyncIsUnlocked {
                deviceSyncToggle
            } else {
                LockedFeatureVeil(
                    headline: "Sync memories to my other devices",
                    detail: "Pro. Approved memories your other signed-in devices backed up are pulled down onto this Mac, end-to-end sealed. BurnBar never sees them.",
                    ctaLabel: "See Pro",
                    icon: "arrow.triangle.2.circlepath",
                    action: { showDeviceSyncUnlockSheet = true },
                    background: { deviceSyncToggle.disabled(true) }
                )
            }
        }
        .settingsAnchor(SettingsAnchor.memorySyncDeviceToggle)
        .sheet(isPresented: $showDeviceSyncUnlockSheet) {
            FeatureUnlockSheet(feature: Self.deviceSyncGatedFeature)
        }
    }

    /// The switch itself — off by default, and reading off whenever the
    /// effective gate is closed (sub-toggle off, backup opt-in off, the fleet
    /// ceiling closed, or no Data Vault entitlement) regardless of what the raw
    /// sub-toggle is persisted as, so a greyed-out switch never appears to
    /// silently be on.
    private var deviceSyncToggle: some View {
        SettingsToggle(
            title: "Sync memories to my other devices",
            subtitle: deviceSyncSubtitle,
            isOn: deviceSyncBinding
        )
        .disabled(!settingsManager.memoryDeviceSyncRowUnlocked)
    }

    private var deviceSyncSubtitle: String {
        // The fleet ceiling FIRST. `memoryApprovedCloudBackupEnabled` folds the
        // Remote Config ceiling into the user opt-in, so a fleet kill switch
        // used to render as "Turn on 'Back up approved memories' first" while
        // that toggle visibly read ON — telling the member to do something they
        // had already done and that would not have helped.
        if !settingsManager.memoryExtractionRemoteConfigEnabled {
            return "Temporarily unavailable — memory sync is paused for all OpenBurnBar users. Nothing you can change on this Mac affects it; it comes back on its own."
        }
        if !settingsManager.memoryApprovedCloudBackupEnabled {
            return "Turn on \"Back up approved memories\" above first. Off by default — pulls your approved memories back down from your other signed-in devices too."
        }
        if !settingsManager.memoryDeviceSyncEntitlementSatisfied {
            return "Requires the Data Vault plan (Pro Max or Ultra). Off by default — pulls your approved memories back down from your other signed-in devices too."
        }
        return "Off by default. When on, approved memories your other signed-in devices backed up are pulled down and merged into this Mac's memory too."
    }

    private var deviceSyncBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.memoryDeviceSyncRowEnabled },
            set: { isOn in
                settingsManager.memoryDeviceSyncOptIn = isOn
                enforceDeviceSyncInboxScope()
            }
        )
    }

    /// Applies the member's decision to the inbox at once, rather than on the
    /// next sync tick. Turning device sync OFF withdraws consent for facts that
    /// are already parked and not yet merged, so those go now and the daemon's
    /// consent marker is withdrawn with them — a member who flips the switch off
    /// and immediately runs an agent must not have a pending drain land anyway.
    /// `MemoryCloudSyncDomain` enforces the same scope every cycle; this is the
    /// immediacy the switch itself promises.
    private func enforceDeviceSyncInboxScope() {
        guard let store = runtimeContext?.chatMemoryStore else { return }
        // Generation BEFORE scope — see `MemoryDeviceSyncInboxGuard.observeGeneration`.
        let observedGeneration = MemoryDeviceSyncInboxGuard.observeGeneration(store: store)
        // The SAME computation `MemoryCloudSyncDomain.gateSnapshot()` uses, by
        // construction. Built here from `memoryDeviceSyncEnabled` alone, this
        // path published a fresh daemon consent marker for a member whose
        // ACCOUNT-wide cloud sync was off — pending remote facts could then
        // drain into the engine until the next refresh tick withdrew it.
        let scope = MemoryDeviceSyncScope.current(account: accountManager, settings: settingsManager)
        Task {
            do {
                try await MemoryDeviceSyncInboxGuard.enforce(
                    scope: scope,
                    observedGeneration: observedGeneration,
                    store: store
                )
            } catch {
                // The next sync tick enforces the same scope, so a failure here
                // delays the purge rather than losing it.
                AppLogger.sync.error(
                    "memory_device_sync_toggle_inbox_guard_failed",
                    metadata: ["error_type": String(describing: type(of: error))]
                )
            }
        }
    }

    /// Pushes the live Data Vault tier into the settings coordinator's
    /// non-persisted entitlement snapshot. Idempotent — safe from `.onAppear`
    /// and every `.onChange(of: deviceSyncEntitlement.cloudTier)` firing.
    /// `MemoryCloudSyncDomain` refreshes the same lever on every sync cycle, so
    /// the pull's gate does not depend on this view having appeared.
    private func refreshDeviceSyncEntitlement() {
        deviceSyncEntitlement.start()
        settingsManager.memoryDeviceSyncEntitlementSatisfied = deviceSyncIsUnlocked
    }

    /// The live Data Vault entitlement, resolved exactly the way
    /// `MemoryCloudModelsSection` resolves it for its own veil.
    private var deviceSyncIsUnlocked: Bool {
        deviceSyncEntitlement.cloudTier.satisfies(Self.deviceSyncGatedFeature.requiredTier)
    }

    // MARK: - Team memory

    /// Team memory (memory program D16). Same entitlement and the same veil as
    /// the device-sync row, because it is the same lane: `TeamMemorySyncGate`
    /// ANDs the whole personal device-sync gate — entitlement included — under
    /// every team, so a member below the tier could not sync a team even with
    /// the switch on. Showing them what the feature is beats a dead grey row.
    ///
    /// The model is built once, lazily, and only when a member is signed in:
    /// its first act is a roster READ, and issuing one for a signed-out window
    /// would be a network call nobody asked for.
    @ViewBuilder
    private var teamMemorySection: some View {
        Group {
            if deviceSyncIsUnlocked {
                if let teamMemoryModel {
                    TeamMemorySection(model: teamMemoryModel)
                } else {
                    Color.clear.frame(height: 0)
                }
            } else {
                LockedFeatureVeil(
                    headline: TeamMemoryCopy.sectionTitle,
                    detail: TeamMemoryCopy.sectionSubtitle,
                    ctaLabel: "See Pro",
                    icon: "person.3.sequence.fill",
                    action: { showTeamMemoryUnlockSheet = true },
                    background: { Color.clear.frame(height: 0) }
                )
            }
        }
        .sheet(isPresented: $showTeamMemoryUnlockSheet) {
            FeatureUnlockSheet(feature: Self.deviceSyncGatedFeature)
        }
        .onAppear {
            guard teamMemoryModel == nil, accountManager.isSignedIn else { return }
            teamMemoryModel = Self.makeTeamMemoryModel(
                settingsManager: settingsManager,
                accountManager: accountManager,
                cloudSyncDomain: runtimeContext?.memoryCloudSyncDomain
            )
        }
    }

    /// Assembles the production seams. Kept `static` so it reads as wiring: the
    /// roster read, the four membership callables and the rotation sequence are
    /// each their own type, and the model holds no Firebase handle itself.
    ///
    /// `personalGateProvider` is the SCOPE, not the sub-toggle (PR 4 review L4).
    /// `MemoryDeviceSyncScope.current(...)` is the one computation of "may a
    /// remote memory reach this device right now" — the four personal memory
    /// levers ANDed with the account levers (Firebase available, signed in,
    /// account cloud sync on) — and it is exactly what `TeamMemorySyncGate`
    /// requires as `deviceSyncGateOpen && accountLeversOpen`. Passing
    /// `memoryDeviceSyncEnabled` alone let a member with account cloud sync off
    /// switch a team on and watch `TeamMemorySyncDomain.runCycle` return `.idle`
    /// with nothing on screen saying why.
    @MainActor
    private static func makeTeamMemoryModel(
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        cloudSyncDomain: MemoryCloudSyncDomain?
    ) -> TeamMemorySectionModel {
        let gateway = CloudSyncFirestoreLiveGateway()
        let callables = FirebaseTeamRosterCallableClient()
        let uid = accountManager.currentUID
        let deviceId = accountManager.deviceId
        let keyRing = KeychainTeamVaultKeyRing()
        let rotator: TeamKeyRotating? = uid.map { uid in
            TeamVaultKeyRotator(
                gateway: gateway,
                uid: uid,
                deviceId: deviceId,
                keyRing: keyRing,
                callables: callables
            )
        }
        // The join half of design §3(b)2. Nil while signed out, exactly like the
        // rotator: both wrap keys AS this account, and there is no account to
        // wrap as.
        let joinerKeys: TeamJoinerKeyIssuing? = uid.map { uid in
            TeamVaultJoinerKeyIssuer(
                gateway: gateway,
                uid: uid,
                deviceId: deviceId,
                keyRing: keyRing,
                callables: callables
            )
        }
        // The FOUNDING half of design §3(b)1, and the one this wiring was missing
        // outright: `bootstrapTeamKeys` had no production caller, so a created
        // team never got a `teamVaultKey_v1` or a `teamSlugKey` on any Mac. Nil
        // while signed out for the same reason as the two above.
        let founderKeys: TeamFounderKeyBootstrapping? = uid.map { uid in
            TeamVaultFounderKeyBootstrapper(
                gateway: gateway,
                uid: uid,
                deviceId: deviceId,
                keyRing: keyRing,
                callables: callables
            )
        }
        return TeamMemorySectionModel(
            roster: FirestoreTeamRosterDirectory(gateway: gateway),
            admin: FirebaseTeamMemoryAdministrator(),
            rotator: rotator,
            joinerKeys: joinerKeys,
            founderKeys: founderKeys,
            uidProvider: { accountManager.currentUID },
            personalGateProvider: {
                MemoryDeviceSyncScope.current(account: accountManager, settings: settingsManager).isOpen
            },
            remoteConfigProvider: {
                (
                    settingsManager.memoryTeamSyncRemoteConfigAllowed,
                    settingsManager.memoryTeamSyncRemoteConfigResolved
                )
            },
            optInProvider: { settingsManager.memoryTeamSyncEnabledTeamIDs },
            optInWriter: { settingsManager.memoryTeamSyncEnabledTeamIDs = $0 },
            // Read from the SAME Keychain ring the sync cycle and the
            // distributor use, so the row cannot report a readiness the lane
            // below it disagrees with.
            keyReadinessProvider: { detail in
                TeamKeyReadiness.resolve(ring: keyRing, detail: detail)
            },
            // The eager half of the leave (PR 4 review §3). Nil only when this
            // settings surface was built without a runtime context, in which
            // case there is no sync lane to invalidate and the next cycle — on
            // whichever process owns one — does it.
            invalidateTeamSync: { [weak cloudSyncDomain] teamID in
                await cloudSyncDomain?.invalidateTeamMemorySync(teamID: teamID)
            }
        )
    }

    // MARK: - Health and status

    /// Per-project memory health. Counters come from the local daemon over the
    /// existing `daemon.memory.analytics` RPC; every finding is one this Mac
    /// measured itself, and the card says so.
    ///
    /// The host picks its own subject from the projects the daemon has already
    /// recorded. Settings has no project scope of its own, and passing that
    /// absence down to the daemon would have it resolve its own working
    /// directory into a phantom project — see `ProjectMemoryHealthModel`.
    @ViewBuilder
    private var memoryHealthSection: some View {
        if let store = runtimeContext?.chatMemoryStore {
            ProjectMemoryHealthCardHost(
                store: store,
                daemonManager: runtimeContext?.daemonManager,
                accountUid: accountManager.userID
            )
            .settingsAnchor(SettingsAnchor.memorySyncHealth)
        }
    }

    /// Both transport cursors, the consent marker's age, and the inbox counts.
    ///
    /// Behind a disclosure because it is a diagnostic: it is the surface a
    /// member opens when memories are not arriving, and the numbers only mean
    /// anything next to the thresholds the row states. Every value is read from
    /// this Mac's own database — nothing here issues a network call or an RPC.
    @ViewBuilder
    private var memorySyncStatusSection: some View {
        if let store = runtimeContext?.chatMemoryStore {
            DisclosureGroup(isExpanded: $isMemorySyncStatusExpanded) {
                MemorySyncDebugRowHost(store: store, accountUid: accountManager.userID)
                    .padding(.top, DesignSystem.Spacing.sm)
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("Memory sync status")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Spacer()
                    Text("Cursors, consent marker, parked inbox")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.22))
            )
            .settingsAnchor(SettingsAnchor.memorySyncStatus)
        }
    }
}
