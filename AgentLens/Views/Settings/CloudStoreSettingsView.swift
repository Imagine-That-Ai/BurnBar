@preconcurrency import SwiftUI
import AppKit
import StoreKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Cloud Store Settings View (macOS)

struct CloudStoreSettingsView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var remoteMCPClients = MacRemoteMCPClientStore()
    @StateObject private var entitlement = MacCloudEntitlementStore.shared
    @StateObject private var purchaseStore = MacHostedQuotaPurchaseStore()
    @State private var showBadgePicker = false
    @State private var billingPeriod: MacCloudBillingPeriod = .monthly

    /// Injected so the Backup & Sync card can read/write the live cloud toggles
    /// and trigger an on-demand session-log backup. Defaulted to the shared
    /// singletons so the `#Preview` (and any zero-arg call site) still builds.
    var settingsManager: SettingsManager = .shared
    var accountManager: AccountManager = .shared
    var dataStore: DataStore?

    /// `onAppear` starts live services (StoreKit catalogue load, backup
    /// catch-up, analytics, remote-MCP Firestore listener) and the
    /// `repeatForever` tier-crest shimmer. Headless test renders set this to
    /// `false`: an off-window `NSHostingView` never fires `onDisappear`, so
    /// on CI the leftover work/animation from a snapshot render wedges the
    /// shared test process and hangs later suites (App PR Gate timeout).
    var startsLiveServicesOnAppear: Bool = true

    @State private var isBackingUp = false
    @State private var backupNoticeError: String?
    @State private var lastManualBackupAt: Date?
    @State private var backupProgress: CloudBackupProgressSnapshot?
    @State private var backupUsage: CloudBackupUsageSnapshot?
    @State private var pendingBackupSessionLogs = 0
    @State private var pendingBackupChatThreads = 0
    @State private var didRequestAutomaticCatchUp = false
    @State private var showingHostedMCPUnlock = false
    @State private var showingMemoryWalkthrough = false

    /// Hosted Remote MCP requires Cloud Pro. When the member doesn't hold it,
    /// the card wears the tier lock badge and routes its setup action to the
    /// evocative unlock sheet instead of the live endpoint.
    private var isHostedMCPUnlocked: Bool {
        entitlement.cloudTier.satisfies(GatedFeature.gatedFeature(.hostedMCP).requiredTier)
    }

    var body: some View {
        ZStack {
            EmberSurfaceBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    hero
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .settingsAnchor(SettingsAnchor.cloudOverview)

                    if entitlement.isActive {
                        auroraMemberCard
                            .padding(.horizontal, 28)
                    }

                    // The full four-tier pricing lineup — matches the marketing
                    // site exactly (Local · Cloud · Cloud Pro · Cloud Ultra).
                    // Shown to everyone: free users to subscribe, members to
                    // compare and upgrade (a Cloud member can jump to Ultra).
                    tierLineup
                        .padding(.horizontal, 28)

                    purchaseSupportRow
                        .padding(.horizontal, 28)

                    backupSyncCard
                        .padding(.horizontal, 28)
                        .settingsAnchor(SettingsAnchor.cloudSyncToggle)

                    capabilityLineup
                        .padding(.horizontal, 28)

                    remoteMCPCard
                        .padding(.horizontal, 28)

                    trustCard
                        .padding(.horizontal, 28)

                    Spacer(minLength: 36)
                }
            }
        }
        .navigationTitle("OpenBurnBar Cloud")
        .sheet(isPresented: $showBadgePicker) {
            CloudBadgePicker()
        }
        .onAppear {
            guard startsLiveServicesOnAppear else { return }
            Analytics.shared.track(.screenViewed, ["surface": "cloud_sync"])
            entitlement.start()
            Task { await purchaseStore.load() }
            refreshBackupState(startAutomaticCatchUp: true)
        }
    }

    // MARK: - Aurora member card (active)
    //
    // Vivid ember/amber/blaze/whimsy burst, foil hairline border, drifting
    // aurora ribbon, large badge halo, PRO + "OPENBURNBAR CLOUD" tag,
    // "Member" in the primary gradient, status pill, Manage + Change badge
    // capsule buttons. Mirrors the iOS/Android member card 1:1.

    @ViewBuilder
    private var auroraMemberCard: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack(alignment: .top) {
            // Backdrop
            shape
                .fill(.ultraThinMaterial)
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.ember.opacity(0.50),
                            DesignSystem.Colors.amber.opacity(0.38),
                            DesignSystem.Colors.blaze.opacity(0.30),
                            DesignSystem.Colors.whimsy.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // Aurora ribbon along the top edge
            LinearGradient(
                colors: [
                    DesignSystem.Colors.hermesAureate.opacity(0.35),
                    DesignSystem.Colors.amber.opacity(0.55),
                    DesignSystem.Colors.ember.opacity(0.40),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 80)
            .frame(maxHeight: .infinity, alignment: .top)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            // Soft radial halo behind the badge
            RadialGradient(
                colors: [
                    DesignSystem.Colors.amber.opacity(0.55),
                    DesignSystem.Colors.ember.opacity(0.25),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 0,
                endRadius: 240
            )
            .blendMode(.plusLighter)

            VStack(spacing: 14) {
                Button { showBadgePicker = true } label: {
                    CloudBadgeWithHalo(size: .large)
                }
                .buttonStyle(.plain)
                .help("Change Cloud badge")
                .padding(.top, 22)

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text("PRO")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [DesignSystem.Colors.ember, DesignSystem.Colors.amber],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            )
                        Text("OPENBURNBAR CLOUD")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(2.0)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Text("Member")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                }

                // Status pill
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("Active")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("·").foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(entitlement.humanStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(DesignSystem.Colors.success.opacity(0.14))
                )
                .overlay(
                    Capsule().stroke(DesignSystem.Colors.success.opacity(0.45), lineWidth: 0.5)
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        auroraManageButton
                        auroraChangeBadgeButton
                    }
                    VStack(spacing: 10) {
                        auroraManageButton
                        auroraChangeBadgeButton
                    }
                }
                .padding(.bottom, 22)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .clipShape(shape)
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.hermesAureate,
                        DesignSystem.Colors.amber,
                        DesignSystem.Colors.ember,
                        DesignSystem.Colors.hermesAureate
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.4
            )
        )
        .shadow(color: DesignSystem.Colors.ember.opacity(0.40), radius: 28, y: 14)
        .shadow(color: DesignSystem.Colors.amber.opacity(0.22), radius: 40, y: 0)
    }

    private var auroraManageButton: some View {
        Button {
            if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("Manage", systemImage: "creditcard.fill")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(AuroraPrimaryButtonStyle())
    }

    private var auroraChangeBadgeButton: some View {
        Button {
            showBadgePicker = true
        } label: {
            Label("Change badge", systemImage: "rosette")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(AuroraSecondaryButtonStyle())
    }

    // MARK: - Backup & Sync (the one actionable card)
    //
    // The rest of this pane explains and sells Cloud; this card is where the
    // user actually *does* something. The master toggle turns on end-to-end
    // encrypted conversation + session-log backup — the exact switch that
    // feeds the cross-device Streams cockpit — alongside the secondary iCloud
    // and chat-thread mirrors, live signed-in / Cloud status, and an
    // on-demand "Back up now". All in the same Aurora glass language.

    private var backupSyncCard: some View {
        AuroraGlassCardMac {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("BACKUP & SYNC", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(2.4)
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Spacer()
                    backupStatusChips
                }

                cloudControlRow(
                    icon: "lock.icloud.fill",
                    tint: DesignSystem.Colors.ember,
                    title: "Conversation & session-log backup",
                    subtitle: "End-to-end encrypted. Mirrors every conversation to the cloud so the Streams cockpit can search them on iPhone, iPad, and Mac.",
                    isOn: backupBinding
                )
                .accessibilityIdentifier("macCloud.backupToggle")

                if settingsManager.conversationBackupEnabled {
                    Divider().background(DesignSystem.Colors.border.opacity(0.4))

                    VStack(spacing: 12) {
                        cloudControlRow(
                            icon: "icloud.fill",
                            tint: DesignSystem.Colors.teal,
                            title: "Mirror sessions to iCloud",
                            subtitle: "Keep a private copy in your own iCloud account for personal restore.",
                            isOn: simpleBinding(\.iCloudSessionMirrorEnabled)
                        )
                        cloudControlRow(
                            icon: "bubble.left.and.bubble.right.fill",
                            tint: DesignSystem.Colors.blaze,
                            title: "Back up chat thread content",
                            subtitle: "Sync full chat threads so you can resume them on any device.",
                            isOn: chatThreadBinding
                        )
                    }

                    if let backupUsage {
                        backupUsageMeter(backupUsage)
                    }

                    backupActionRow

                    if isBackingUp, let backupProgress {
                        backupProgressPanel(backupProgress)
                    } else if pendingBackupSessionLogs > 0 || pendingBackupChatThreads > 0 {
                        backupQueueSummary
                    }
                }

                if let backupNoticeError {
                    Label(backupNoticeError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("macCloud.backupError")
                } else if !accountManager.isSignedIn {
                    backupHint(
                        "Sign in to OpenBurnBar to start backing up your conversations.",
                        icon: "person.crop.circle.badge.exclamationmark"
                    )
                } else if !entitlement.isActive {
                    backupHint(
                        "Searchable Streams cockpit needs OpenBurnBar Cloud. Backups still upload fully encrypted.",
                        icon: "sparkles"
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var backupQueueSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.amber)
            Text(backupQueueSummaryText)
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.45))
        )
    }

    private var backupQueueSummaryText: String {
        switch (pendingBackupSessionLogs, pendingBackupChatThreads) {
        case (let logs, 0):
            return "\(logs) conversation\(logs == 1 ? "" : "s") waiting to back up."
        case (0, let threads):
            return "\(threads) chat thread\(threads == 1 ? "" : "s") ready to sync."
        case (let logs, let threads):
            return "\(logs) conversation\(logs == 1 ? "" : "s") and \(threads) chat thread\(threads == 1 ? "" : "s") waiting."
        default:
            return "Everything is backed up."
        }
    }

    private func backupUsageMeter(_ usage: CloudBackupUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Backup usage", systemImage: "externaldrive.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: 8)
                Text(usage.isWithinLimits ? "Included" : "Limit reached")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(usage.isWithinLimits ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill((usage.isWithinLimits ? DesignSystem.Colors.success : DesignSystem.Colors.warning).opacity(0.14))
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                meterRow(
                    title: "Conversation backup",
                    value: "\(CloudBackupUsageSnapshot.formatBytes(usage.rawTranscriptBytes)) of \(CloudBackupUsageSnapshot.formatBytes(usage.limits.transcriptByteLimit))",
                    fraction: usage.transcriptUsageFraction,
                    tint: DesignSystem.Colors.ember
                )
                meterRow(
                    title: "Searchable index",
                    value: "\(CloudBackupUsageSnapshot.formatBytes(usage.estimatedSearchIndexBytes)) of \(CloudBackupUsageSnapshot.formatBytes(usage.limits.searchableIndexByteLimit))",
                    fraction: usage.searchIndexUsageFraction,
                    tint: DesignSystem.Colors.teal
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                backupMetricPill(title: "Conversations", value: "\(usage.conversationCount)")
                backupMetricPill(title: "Waiting", value: "\(usage.pendingConversationCount)")
                backupMetricPill(title: "Indexed parts", value: "\(usage.searchChunkCount)")
            }

            if let blockingReason = usage.blockingReason {
                Label(blockingReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.6)
        )
        .accessibilityIdentifier("macCloud.backupUsage")
    }

    private func meterRow(title: String, value: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
                .tint(tint)
        }
    }

    private func backupProgressPanel(_ progress: CloudBackupProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.phaseTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(progress.detailLine)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("\(Int((progress.overallFraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.ember)
            }

            ProgressView(value: max(0, min(1, progress.overallFraction)))
                .progressViewStyle(.linear)
                .tint(DesignSystem.Colors.ember)

            if let current = progress.currentLabel, progress.phase != .complete {
                Label(current, systemImage: "doc.text.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                backupMetricPill(
                    title: "Records",
                    value: "\(progress.completedWorkItems)/\(max(progress.totalWorkItems, progress.completedWorkItems))"
                )
                backupMetricPill(
                    title: "Uploaded",
                    value: "\(progress.uploadedSessionLogs)"
                )
                backupMetricPill(
                    title: "Storage",
                    value: "\(progress.storageUploads)"
                )
                backupMetricPill(
                    title: "Encrypted",
                    value: CloudBackupProgressSnapshot.formatBytes(progress.encryptedBytes)
                )
                backupMetricPill(
                    title: "Speed",
                    value: CloudBackupProgressSnapshot.formatRate(bytesPerSecond: progress.uploadBytesPerSecond)
                )
                backupMetricPill(
                    title: "Throughput",
                    value: CloudBackupProgressSnapshot.formatRate(recordsPerSecond: progress.recordsPerSecond)
                )
                backupMetricPill(
                    title: "Searchable",
                    value: "\(progress.searchIndexCommits)"
                )
                backupMetricPill(
                    title: "Elapsed",
                    value: formatElapsed(progress.elapsedSeconds)
                )
            }

            if let operation = progress.currentOperation, progress.phase != .complete {
                Text(operation)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignSystem.Colors.ember.opacity(0.28), lineWidth: 0.6)
        )
        .accessibilityIdentifier("macCloud.backupProgress")
    }

    private func backupMetricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.08))
        )
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    @MainActor
    private func refreshPendingBackupCounts() async {
        guard let dataStore else {
            pendingBackupSessionLogs = 0
            pendingBackupChatThreads = 0
            return
        }
        pendingBackupSessionLogs = (try? await dataStore.countUnsyncedSessionLogs()) ?? 0
        pendingBackupChatThreads = (try? await dataStore.fetchChatThreadSummaries(limit: 500).count) ?? 0
    }

    @MainActor
    private func refreshBackupUsage() async {
        guard let dataStore else {
            backupUsage = nil
            return
        }
        backupUsage = try? await dataStore.backupUsageSnapshot()
    }

    private func refreshBackupState(startAutomaticCatchUp: Bool = false) {
        Task { @MainActor in
            await refreshPendingBackupCounts()
            await refreshBackupUsage()
            if startAutomaticCatchUp {
                startAutomaticCatchUpIfNeeded()
            }
        }
    }

    private func startAutomaticCatchUpIfNeeded() {
        guard settingsManager.conversationBackupEnabled,
              accountManager.isSignedIn,
              dataStore != nil,
              !isBackingUp,
              !didRequestAutomaticCatchUp else { return }
        guard pendingBackupSessionLogs > 0 || pendingBackupChatThreads > 0 else { return }
        if let blockingReason = backupUsage?.blockingReason {
            backupNoticeError = blockingReason
            return
        }
        didRequestAutomaticCatchUp = true
        triggerBackup()
    }

    private var backupActionRow: some View {
        HStack(spacing: 12) {
            Button {
                triggerBackup()
            } label: {
                if isBackingUp {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Backing up…")
                    }
                    .font(.system(size: 13, weight: .semibold))
                } else {
                    Label("Back up now", systemImage: "arrow.up.to.line")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
            .disabled(!accountManager.isSignedIn || isBackingUp || dataStore == nil || backupUsage?.blockingReason != nil)
            .accessibilityIdentifier("macCloud.backupNow")

            if let lastManualBackupAt, !isBackingUp {
                Text("Last backup \(Self.relativeFormatter.localizedString(for: lastManualBackupAt, relativeTo: Date()))")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    private var backupStatusChips: some View {
        HStack(spacing: 6) {
            statusChip(
                active: accountManager.isSignedIn,
                label: accountManager.isSignedIn ? "Signed in" : "Signed out",
                icon: accountManager.isSignedIn ? "checkmark.seal.fill" : "person.crop.circle"
            )
            statusChip(
                active: entitlement.isActive,
                label: entitlement.isActive ? "Cloud" : "Free",
                icon: entitlement.isActive ? "cloud.fill" : "cloud"
            )
        }
    }

    private func statusChip(active: Bool, label: String, icon: String) -> some View {
        let tint = active ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(label).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
    }

    private func backupHint(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11))
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cloudControlRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DesignSystem.Colors.ember)
        }
    }

    // MARK: Backup bindings + action

    /// Master switch — flips both the session-log and conversation backup
    /// flags (via `conversationBackupEnabled`), records consent, and kicks an
    /// immediate backup on enable so data starts flowing right away.
    private var backupBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.conversationBackupEnabled },
            set: { newValue in
                settingsManager.conversationBackupEnabled = newValue
                settingsManager.sessionLogCloudBackupConsentShown = true
                didRequestAutomaticCatchUp = false
                if newValue {
                    refreshBackupState(startAutomaticCatchUp: true)
                } else {
                    backupNoticeError = nil
                    backupProgress = nil
                    refreshBackupState()
                }
            }
        )
    }

    private var chatThreadBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.chatThreadContentCloudBackupEnabled },
            set: { newValue in
                settingsManager.chatThreadContentCloudBackupEnabled = newValue
                if newValue { settingsManager.chatThreadContentCloudBackupConsentShown = true }
            }
        )
    }

    private func simpleBinding(_ keyPath: ReferenceWritableKeyPath<SettingsManager, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsManager[keyPath: keyPath] },
            set: { settingsManager[keyPath: keyPath] = $0 }
        )
    }

    /// Builds a transient `CloudSyncCoordinator` from the injected dependencies
    /// and uploads pending session logs (and chat threads) immediately. The
    /// coordinator's session-log path runs the cockpit-facet backfill, so the
    /// Streams cockpit fills in on the next refresh. Idempotent.
    private func triggerBackup() {
        guard let dataStore, accountManager.isSignedIn, !isBackingUp else { return }
        isBackingUp = true
        backupNoticeError = nil
        backupProgress = nil
        let sm = settingsManager
        let am = accountManager
        let ds = dataStore
        Task { @MainActor in
            backupUsage = try? await ds.backupUsageSnapshot()
            if let blockingReason = backupUsage?.blockingReason {
                backupNoticeError = blockingReason
                isBackingUp = false
                return
            }
            let coordinator = CloudSyncCoordinator(
                dataStore: ds,
                accountManager: am,
                settingsManager: sm
            )
            await coordinator.performManualBackup { snapshot in
                backupProgress = snapshot
            }
            isBackingUp = false
            refreshBackupState()
            if let error = coordinator.lastSyncError ?? backupProgress?.errorMessage {
                backupNoticeError = Self.userFacingBackupError(error)
            } else if backupProgress?.phase == .failed {
                backupNoticeError = Self.userFacingBackupError(backupProgress?.errorMessage ?? "Backup failed.")
            } else {
                lastManualBackupAt = Date()
                backupNoticeError = nil
            }
        }
    }

    private static func userFacingBackupError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Backup failed. Try again." }
        let lower = trimmed.lowercased()
        if lower == "internal"
            || lower.contains("code=internal")
            || lower.contains("error 13")
            || lower.contains("signblob")
            || lower.contains("signed url") {
            return "Cloud backup could not create a secure upload link. Try again in a minute."
        }
        if lower.contains("unauthenticated") || lower.contains("auth") && lower.contains("expired") {
            return "Sign in again to back up cloud conversations."
        }
        if lower.contains("permission") || lower.contains("denied") {
            return "Cloud backup is not available for this account yet."
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("timed out") {
            return "Network connection failed during backup. Try again when you are online."
        }
        return trimmed
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            Button {
                showBadgePicker = true
            } label: {
                CloudBadgeWithHalo(size: .large)
            }
            .buttonStyle(.plain)
            .help("Change Cloud badge")

            VStack(spacing: 6) {
                Text("OPENBURNBAR")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text("Cloud")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)

                Text("Hosted quota refresh. Chat that follows you. Mac AI anywhere. From $7.99/mo.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tier lineup
    //
    // The four marketing tiers, rendered as stacked Aurora glass cards that match
    // burnbar.ai/pricing exactly: OpenBurnBar Local (free, no crest), BurnBar
    // Cloud, BurnBar Cloud Pro, and BurnBar Cloud Ultra. Each paid card carries
    // its transparent crest and a subtle per-tier holographic accent (the crest
    // silhouette masked over an iridescent gradient, low opacity) behind the
    // glass so copy stays fully legible. Prices come live from StoreKit.

    private var tierLineup: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    tierLineupEyebrow
                    Spacer()
                    tierLineupTagline
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    tierLineupEyebrow
                    tierLineupTagline
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Billing period", selection: $billingPeriod) {
                ForEach(MacCloudBillingPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("macCloudStore.billingPeriod")

            VStack(spacing: 16) {
                ForEach(MacPricingTierModel.all) { model in
                    tierCard(model)
                }
            }

            if let error = purchaseStore.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("macCloudStore.purchaseError")
            }
        }
    }

    private var tierLineupEyebrow: some View {
        Text("CHOOSE YOUR PLAN")
            .font(.system(size: 11, weight: .heavy))
            .tracking(2.4)
            .foregroundStyle(DesignSystem.Colors.ember)
    }

    private var tierLineupTagline: some View {
        Text("Free where it should be · paid where it costs us money")
            .font(.system(size: 11))
            .foregroundStyle(DesignSystem.Colors.textMuted)
    }

    @ViewBuilder
    private func tierCard(_ model: MacPricingTierModel) -> some View {
        let tier = model.tier
        let currentTier = entitlement.currentTier
        let isCurrent = currentTier == model.entitlementTier && model.entitlementTier != .free
        let isOwned = model.entitlementTier != .free && currentTier >= model.entitlementTier
        let isBusy = purchaseStore.purchasingProductID == tier.productID(for: billingPeriod)

        AuroraGlassCardMac {
            ZStack(alignment: .topTrailing) {
                // Per-tier holographic accent — the crest silhouette filled with
                // an iridescent gradient, kept faint so copy stays crisp.
                if let crestAsset = model.crestAsset {
                    TierHolographicAccent(
                        crestAsset: crestAsset,
                        palette: model.holoPalette,
                        reduceMotion: reduceMotion,
                        animates: startsLiveServicesOnAppear
                    )
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 14) {
                    tierHeader(model, isCurrent: isCurrent)
                    tierPriceRow(model)

                    Text(model.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.bullets, id: \.self) { bullet in
                            tierBullet(bullet, accent: model.accent)
                        }
                    }
                    .padding(.top, 2)

                    if let included = model.includedNote {
                        tierIncludedNote(included)
                    }

                    tierActionRow(model, isOwned: isOwned, isCurrent: isCurrent, isBusy: isBusy)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .top) {
            if isCurrent {
                tierCurrentBadge
                    .offset(y: -10)
            } else if let highlight = model.highlightBadge {
                tierHighlightBadge(highlight, accent: model.accent)
                    .offset(y: -10)
            }
        }
    }

    private func tierHeader(_ model: MacPricingTierModel, isCurrent: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.eyebrow)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.8)
                    .foregroundStyle(model.accent)
                Text(model.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            Spacer(minLength: 8)
            if let crestAsset = model.crestAsset {
                Image(crestAsset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .shadow(color: model.accent.opacity(0.35), radius: 8, y: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    private func tierPriceRow(_ model: MacPricingTierModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if model.tier == .local {
                Text("$0")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("forever")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                Text(
                    purchaseStore.displayPrice(
                        for: model.tier,
                        billingPeriod: billingPeriod
                    ) ?? "—"
                )
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
                    .accessibilityIdentifier("macCloudStore.price.\(model.tier.rawValue)")
                Text(billingPeriod.priceSuffix)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    private func tierBullet(_ text: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
                .padding(.top, 1.5)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func tierIncludedNote(_ note: MacPricingTierModel.IncludedNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            ForEach(note.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.45))
        )
    }

    @ViewBuilder
    private func tierActionRow(
        _ model: MacPricingTierModel,
        isOwned: Bool,
        isCurrent: Bool,
        isBusy: Bool
    ) -> some View {
        if model.tier == .local {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text("Installed — no account, nothing to buy")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        } else if isCurrent {
            Button {
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Manage subscription", systemImage: "creditcard.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
            .padding(.top, 4)
        } else {
            Button {
                subscribeToSelectedCadence(model.tier) // cov:ignore -- button chrome; the action is unit-tested via subscribeToSelectedCadence(_:)
            } label: {
                Group {
                    if isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Opening App Store purchase")
                        }
                    } else {
                        Label(
                            isOwned ? "Switch to \(model.name)" : "\(model.ctaVerb) \(model.name)",
                            systemImage: "creditcard.fill"
                        )
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
            .disabled(purchaseStore.isPurchasing)
            .padding(.top, 4)
            .accessibilityIdentifier("macCloudStore.subscribe.\(model.tier.rawValue)")
        }
    }

    /// Starts the StoreKit purchase for `tier` at the billing cadence the
    /// pane's segmented picker currently selects. Internal (not private) so
    /// unit tests can drive the exact action the subscribe button performs.
    @discardableResult
    func subscribeToSelectedCadence(_ tier: MacCloudPricingTier) -> Task<Void, Never> {
        Task {
            await purchaseStore.purchase(
                tier: tier,
                billingPeriod: billingPeriod
            )
        }
    }

    private var tierCurrentBadge: some View {
        Text("YOUR PLAN")
            .font(.system(size: 9, weight: .heavy))
            .tracking(1.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [DesignSystem.Colors.success, DesignSystem.Colors.success.opacity(0.75)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
            .shadow(color: DesignSystem.Colors.success.opacity(0.4), radius: 8, y: 3)
    }

    private func tierHighlightBadge(_ text: String, accent: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .tracking(1.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.7)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
            .shadow(color: accent.opacity(0.4), radius: 8, y: 3)
    }

    // MARK: - Purchase support row (restore + legal + disclosure)

    private var purchaseSupportRow: some View {
        AuroraGlassCardMac(cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        restorePurchasesButton
                        MacCloudStoreLegalLinks()
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            restorePurchasesButton
                            Spacer(minLength: 0)
                        }
                        MacCloudStoreLegalLinks()
                    }
                }

                subscriptionDetails
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var restorePurchasesButton: some View {
        Button {
            Task { await purchaseStore.restorePurchases() }
        } label: {
            Label("Restore Purchases", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(AuroraSecondaryButtonStyle())
        .disabled(purchaseStore.isLoading || purchaseStore.isPurchasing)
    }

    private var subscriptionDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUBSCRIPTION DETAILS")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(
                "BurnBar Cloud, Cloud Pro, and Cloud Ultra are auto-renewable subscriptions billed through the App Store. " +
                "Cloud adds hosted quota refresh, encrypted backup and resume, cloud search, synced agent memory, and remote relay. " +
                "Cloud Pro adds Floo phone-to-Mac control and supervised Agent Control with prepaid hosted allowances. " +
                "Cloud Ultra keeps all of Pro and gives your agents 10× private memory — sealed on your device, with hosted recall over encrypted structures that still expose some access patterns. " +
                "Prices shown are live from the App Store; Apple bills your Apple ID and you can cancel anytime in Apple ID subscriptions."
            )
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("macCloudStore.subscriptionDisclosure")
    }

    // MARK: - Capability lineup

    private var capabilityLineup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("WHAT'S INCLUDED")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2.4)
                    .foregroundStyle(DesignSystem.Colors.ember)
                Spacer()
            }

            VStack(spacing: 12) {
                capabilityRow(
                    icon: "cloud.fill",
                    tint: DesignSystem.Colors.ember,
                    title: "Hosted Codex quota",
                    detail: "Refresh Codex quota from any signed-in device. We run the runner; you get the dial."
                )
                capabilityRow(
                    icon: "arrow.triangle.2.circlepath",
                    tint: DesignSystem.Colors.amber,
                    title: "Conversation backup & resume",
                    detail: "Encrypted in transit, restored across iPhone, iPad, and Mac. Pick up exactly where you left off."
                )
                capabilityRow(
                    icon: "text.alignleft",
                    tint: DesignSystem.Colors.blaze,
                    title: "Full session-log sync",
                    detail: "Every tool call, every chunk, every cost line — mirrored to the cloud and searchable on every device."
                )
                capabilityRow(
                    icon: "antenna.radiowaves.left.and.right",
                    tint: DesignSystem.Colors.whimsy,
                    title: "Hermes remote relay",
                    detail: "Reach your Mac's Hermes from anywhere over a verified WebSocket. App Check + Apple JWS, end-to-end."
                )
            }
        }
    }

    private func capabilityRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        AuroraGlassCardMac(cornerRadius: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Remote MCP

    private var remoteMCPCard: some View {
        AuroraGlassCardMac {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("REMOTE MCP", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(2.4)
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Spacer()
                    if isHostedMCPUnlocked {
                        Label("Active", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DesignSystem.Colors.success)
                    } else {
                        TierLockBadge(tier: GatedFeature.gatedFeature(.hostedMCP).requiredTier)
                    }
                }
                .settingsAnchor(SettingsAnchor.cloudRemoteMCP)

                Text("Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted hosted session-memory search. Direct HTTP uses the hosted endpoint; the local shim keeps decrypted snippets on-device.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                remoteMCPCommandRow(label: "Endpoint", value: MemoryWalkthroughContent.endpoint)
                    .settingsAnchor(SettingsAnchor.cloudRemoteMCP)
                remoteMCPCommandRow(label: "Stdio shim", value: MemoryWalkthroughContent.shimCommand)
                    .settingsAnchor(SettingsAnchor.cloudRemoteMCPConnect)
                remoteMCPCommandRow(label: "Doctor", value: MemoryWalkthroughContent.doctorCommand)
                    .settingsAnchor(SettingsAnchor.cloudRemoteMCPDoctor)

                MacRemoteMCPConnectedClientsSection(store: remoteMCPClients)

                HStack(spacing: 16) {
                    if isHostedMCPUnlocked {
                        Link(destination: URL(string: "https://burnbar.ai/product")!) {
                            HStack(spacing: 6) {
                                Text("Open Remote MCP setup")
                                Image(systemName: "arrow.up.right.square.fill")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.ember)
                        }
                    } else {
                        Button {
                            showingHostedMCPUnlock = true
                        } label: {
                            HStack(spacing: 6) {
                                Text("See what Hosted MCP unlocks")
                                Image(systemName: "sparkle")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.ember)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        AppCommandRouter.shared.handleLinkCli()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal.fill")
                            Text("Link this Mac's CLI")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.ember)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showingMemoryWalkthrough = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "brain.head.profile")
                            Text("How Memory works")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.ember)
                    }
                    .buttonStyle(.plain)
                    .help("Take the one-minute tour of memory and the Memory MCP")
                    .settingsAnchor(SettingsAnchor.cloudMemoryTour)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard startsLiveServicesOnAppear else { return }
            remoteMCPClients.startListening()
        }
        .onDisappear { remoteMCPClients.stopListening() }
        .sheet(isPresented: $showingHostedMCPUnlock) {
            FeatureUnlockSheet(feature: GatedFeature.gatedFeature(.hostedMCP))
        }
        .sheet(isPresented: $showingMemoryWalkthrough) {
            MemoryMCPWalkthroughView()
        }
    }

    private func remoteMCPCommandRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Trust

    private var trustCard: some View {
        AuroraGlassCardMac {
            VStack(alignment: .leading, spacing: 12) {
                Text("THE TRUST MODEL")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2.4)
                    .foregroundStyle(DesignSystem.Colors.ember)

                trustBullet(
                    icon: "checkmark.shield.fill",
                    title: "Apple-verified",
                    detail: "Every transaction JWS is checked against Apple's root certificates server-side."
                )
                trustBullet(
                    icon: "server.rack",
                    title: "UID-bound",
                    detail: "Each purchase is bound to your Firebase UID via a signed appAccountToken."
                )
                trustBullet(
                    icon: "hand.raised.fill",
                    title: "Cancel anytime",
                    detail: "Managed by Apple in Settings → Apple ID. We never store payment details."
                )

                Link(destination: URL(string: "https://burnbar.ai/pricing")!) {
                    HStack(spacing: 6) {
                        Text("Read the Hosted Quota Sync technical doc")
                        Image(systemName: "arrow.up.right.square.fill")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.ember)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trustBullet(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.amber)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Cloud Store Settings (macOS)") {
    CloudStoreSettingsView()
        .frame(width: 720, height: 600)
}
