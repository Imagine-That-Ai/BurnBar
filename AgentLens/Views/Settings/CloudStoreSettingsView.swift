@preconcurrency import SwiftUI
import AppKit
import StoreKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Cloud Store Settings View (macOS)
//
// Aurora-language parity with the iOS `CloudStoreView`. Warm
// `EmberSurfaceBackground`, glass cards with ember-tinted hairlines,
// primary-gradient capsule CTAs, SF-Rounded display, the user-selectable
// `CloudBadge` as the hero brand mark, an aurora-burst member card that
// matches the iOS YouTab certificate row exactly.
//
private enum MacCloudStoreLegalURLs {
    static let privacy = URL(string: "https://burnbar.ai/legal/privacy-policy")!
    static let terms = URL(string: "https://burnbar.ai/legal/terms")!
}

struct CloudStoreSettingsView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var remoteMCPClients = MacRemoteMCPClientStore()
    @StateObject private var entitlement = MacCloudEntitlementStore.shared
    @StateObject private var purchaseStore = MacHostedQuotaPurchaseStore()
    @State private var showBadgePicker = false

    /// Injected so the Backup & Sync card can read/write the live cloud toggles
    /// and trigger an on-demand session-log backup. Defaulted to the shared
    /// singletons so the `#Preview` (and any zero-arg call site) still builds.
    var settingsManager: SettingsManager = .shared
    var accountManager: AccountManager = .shared
    var dataStore: DataStore? = nil

    @State private var isBackingUp = false
    @State private var backupNoticeError: String?
    @State private var lastManualBackupAt: Date?
    @State private var backupProgress: CloudBackupProgressSnapshot?
    @State private var backupUsage: CloudBackupUsageSnapshot?
    @State private var pendingBackupSessionLogs = 0
    @State private var pendingBackupChatThreads = 0
    @State private var didRequestAutomaticCatchUp = false

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
                    } else {
                        planCard
                            .padding(.horizontal, 28)
                    }

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

                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Manage", systemImage: "creditcard.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())

                    Button {
                        showBadgePicker = true
                    } label: {
                        Label("Change badge", systemImage: "rosette")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
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

    private func refreshPendingBackupCounts() {
        guard let dataStore else {
            pendingBackupSessionLogs = 0
            pendingBackupChatThreads = 0
            return
        }
        pendingBackupSessionLogs = (try? dataStore.countUnsyncedSessionLogs()) ?? 0
        pendingBackupChatThreads = (try? dataStore.fetchChatThreadSummaries(limit: 500).count) ?? 0
    }

    private func refreshBackupUsage() {
        guard let dataStore else {
            backupUsage = nil
            return
        }
        backupUsage = try? dataStore.backupUsageSnapshot()
    }

    private func refreshBackupState(startAutomaticCatchUp: Bool = false) {
        refreshPendingBackupCounts()
        refreshBackupUsage()
        if startAutomaticCatchUp {
            startAutomaticCatchUpIfNeeded()
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
        refreshBackupUsage()
        if let blockingReason = backupUsage?.blockingReason {
            backupNoticeError = blockingReason
            return
        }
        isBackingUp = true
        backupNoticeError = nil
        backupProgress = nil
        let sm = settingsManager
        let am = accountManager
        let ds = dataStore
        Task { @MainActor in
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

                Text("Hosted Codex refresh. Chat that follows you. Mac AI anywhere. From $4.99/mo.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Plan card

    private var planCard: some View {
        AuroraGlassCardMac {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MEMBERSHIP")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(2.4)
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Spacer()
                    Text("MONTHLY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .background(
                            Capsule().fill(.ultraThinMaterial)
                        )
                        .overlay(
                            Capsule().stroke(DesignSystem.Colors.border, lineWidth: 0.6)
                        )
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$4.99")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                    Text("/ month")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Text("Apple-verified, billed monthly via the App Store. Manage or cancel anytime in Settings -> Apple ID.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await purchaseStore.purchase() }
                } label: {
                    if purchaseStore.isPurchasing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Opening App Store purchase")
                        }
                        .font(.system(size: 14, weight: .semibold))
                    } else {
                        Label(purchaseButtonTitle, systemImage: "creditcard.fill")
                        .font(.system(size: 14, weight: .semibold))
                    }
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .disabled(purchaseStore.isPurchasing)

                HStack(spacing: 10) {
                    Button {
                        Task { await purchaseStore.restorePurchases() }
                    } label: {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                    .disabled(purchaseStore.isLoading || purchaseStore.isPurchasing)

                    MacCloudStoreLegalLinks()
                }

                subscriptionDetails

                if let error = purchaseStore.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("macCloudStore.purchaseError")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var purchaseButtonTitle: String {
        if let product = purchaseStore.product {
            return "Subscribe for \(product.displayPrice) / month"
        }
        return "Subscribe with App Store"
    }

    private var subscriptionDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUBSCRIPTION DETAILS")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("OpenBurnBar Cloud Monthly is an auto-renewable 1 month subscription. Each billing period includes Hosted Codex quota refresh, Conversation Backup & Resume, Full Session-Log Sync, and Hermes Remote Relay. Apple bills your Apple ID and you can cancel anytime in Apple ID subscriptions.")
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
                    Label("Cloud only", systemImage: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Text("Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted hosted session-memory search. Direct HTTP uses the hosted endpoint; the local shim keeps decrypted snippets on-device.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                remoteMCPCommandRow(label: "Endpoint", value: "https://mcp.burnbar.ai/mcp")
                remoteMCPCommandRow(label: "Stdio shim", value: "openburnbar-mcp-remote mcp serve")
                remoteMCPCommandRow(label: "Doctor", value: "openburnbar mcp doctor")

                MacRemoteMCPConnectedClientsSection(store: remoteMCPClients)

                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://burnbar.ai/product")!) {
                        HStack(spacing: 6) {
                            Text("Open Remote MCP setup")
                            Image(systemName: "arrow.up.right.square.fill")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.ember)
                    }

                    Button(action: {
                        AppCommandRouter.shared.handleLinkCli()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal.fill")
                            Text("Link this Mac's CLI")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.ember)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { remoteMCPClients.startListening() }
        .onDisappear { remoteMCPClients.stopListening() }
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

// MARK: - Aurora glass card (macOS)
//
// Single chrome primitive used everywhere on this pane. UltraThinMaterial
// + warm `cardGradient` overlay + ember-tinted hairline. Replaces the old
// `MercuryFoilCard`.

private struct AuroraGlassCardMac<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DesignSystem.Colors.cardGradient)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.30),
                                DesignSystem.Colors.border.opacity(0.50),
                                DesignSystem.Colors.blaze.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.10), radius: 14, y: 6)
    }
}

// MARK: - Aurora primary button (macOS)
//
// Ember→amber gradient capsule with a thin amber hairline + ember-tinted
// drop shadow. Drop-in replacement for the iOS `.aurora(.primary)` style.

private struct AuroraPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.primaryGradient)
                    .opacity(configuration.isPressed ? 0.90 : 1.0)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.amber.opacity(0.55), lineWidth: 1.0)
            )
            .shadow(
                color: DesignSystem.Colors.ember.opacity(0.30),
                radius: configuration.isPressed ? 6 : 12,
                y: configuration.isPressed ? 2 : 6
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Quieter sibling — `.ultraThinMaterial` capsule with a thin border. For
/// "Change badge" / "Restore" affordances next to a primary CTA.
private struct AuroraSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.65), lineWidth: 0.6)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct MacCloudStoreLegalLinks: View {
    var body: some View {
        HStack(spacing: 8) {
            Link("Privacy Policy", destination: MacCloudStoreLegalURLs.privacy)
            Text("·")
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Link("Terms of Use (EULA)", destination: MacCloudStoreLegalURLs.terms)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(DesignSystem.Colors.ember)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("macCloudStore.legalLinks")
    }
}

@MainActor
private final class MacHostedQuotaPurchaseStore: ObservableObject {
    static let productID = "com.openburnbar.hostedQuotaSync.cloud.monthly"
    static let entitlementProductIDs: Set<String> = [
        "com.openburnbar.hostedQuotaSync.cloud.monthly",
        "com.openburnbar.hostedQuotaSync.monthly",
        "com.openburnbar.computerUse.monthly",
        "com.openburnbar.proMax.bundle.monthly",
        "com.openburnbar.hostedComputerUseSync.monthly",
        "com.openburnbar.proMax.monthly",
        "com.openburnbar.pro.monthly"
    ]

    @Published private(set) var product: Product?
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var error: String?

    private let functions = Functions.functions(region: "us-central1")
    private var transactionUpdatesTask: Task<Void, Never>?

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func load() async {
        startObservingTransactionUpdates()
        await loadProductMetadata()
    }

    func purchase() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        error = nil
        defer { isPurchasing = false }

        do {
            if product == nil {
                await loadProductMetadata()
            }
            guard let product else {
                throw MacHostedQuotaPurchaseError.productUnavailable
            }

            let signedInUser = Auth.auth().currentUser.flatMap { $0.isAnonymous ? nil : $0 }
            let purchaseOptions: Set<Product.PurchaseOption>
            if signedInUser != nil {
                purchaseOptions = [.appAccountToken(try await mintAppAccountToken())]
            } else {
                purchaseOptions = []
            }

            let result = try await product.purchase(options: purchaseOptions)
            switch result {
            case .success(let verification):
                let transaction = try checked(verification)
                if signedInUser != nil {
                    try await verifyHostedQuotaEntitlement(
                        signedTransactionJWS: verification.jwsRepresentation,
                        productID: transaction.productID
                    )
                    await transaction.finish()
                } else {
                    await transaction.finish()
                    error = "Apple purchase completed. Sign in to OpenBurnBar and tap Restore Purchases so OpenBurnBar Cloud can link this subscription to your account."
                }
            case .pending:
                error = "Apple is still processing this purchase. OpenBurnBar will update when the transaction completes."
            case .userCancelled:
                break
            @unknown default:
                error = "Apple returned an unknown purchase state. Try Restore Purchases after the App Store finishes processing."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restorePurchases() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            guard Auth.auth().currentUser?.isAnonymous == false else {
                error = "Sign in to OpenBurnBar before restoring purchases so Apple can link OpenBurnBar Cloud to your account."
                return
            }

            if let entitlement = await findCurrentEntitlement() {
                try await restoreHostedQuotaEntitlement(
                    productID: entitlement.productID,
                    signedTransactionJWS: entitlement.jws
                )
            } else {
                try await restoreHostedQuotaEntitlement(
                    productID: Self.productID,
                    signedTransactionJWS: nil
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadProductMetadata() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            if self.error == nil {
                self.error = error.localizedDescription
            }
        }
    }

    private func startObservingTransactionUpdates() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task.detached { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.handle(transactionUpdate: update)
            }
        }
    }

    private func handle(transactionUpdate update: VerificationResult<StoreKit.Transaction>) async {
        do {
            let transaction = try checked(update)
            guard Self.entitlementProductIDs.contains(transaction.productID) else { return }
            guard Auth.auth().currentUser?.isAnonymous == false else { return }
            try await verifyHostedQuotaEntitlement(
                signedTransactionJWS: update.jwsRepresentation,
                productID: transaction.productID
            )
            await transaction.finish()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func findCurrentEntitlement() async -> (productID: String, jws: String)? {
        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try checked(result)
                guard Self.entitlementProductIDs.contains(transaction.productID) else { continue }
                guard transaction.revocationDate == nil else { continue }
                if let expirationDate = transaction.expirationDate, expirationDate <= Date() {
                    continue
                }
                return (transaction.productID, result.jwsRepresentation)
            } catch {
                continue
            }
        }
        return nil
    }

    private func mintAppAccountToken() async throws -> UUID {
        let result = try await functions.httpsCallable("beginEntitlementBinding").call([
            "productID": Self.productID,
            "clientPlatform": "macos"
        ])
        guard
            let dict = result.data as? [String: Any],
            let rawToken = dict["appAccountToken"] as? String,
            let token = UUID(uuidString: rawToken)
        else {
            throw MacHostedQuotaPurchaseError.invalidBindingToken
        }
        return token
    }

    private func verifyHostedQuotaEntitlement(
        signedTransactionJWS: String,
        productID: String
    ) async throws {
        _ = try await functions.httpsCallable("verifyHostedQuotaEntitlement").call([
            "signedTransactionJWS": signedTransactionJWS,
            "productID": productID
        ])
    }

    private func restoreHostedQuotaEntitlement(
        productID: String,
        signedTransactionJWS: String?
    ) async throws {
        var payload: [String: Any] = ["productID": productID]
        if let signedTransactionJWS, !signedTransactionJWS.isEmpty {
            payload["signedTransactionJWS"] = signedTransactionJWS
        }
        _ = try await functions.httpsCallable("restoreHostedQuotaEntitlement").call(payload)
    }

    private func checked<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }
}

private enum MacHostedQuotaPurchaseError: LocalizedError {
    case productUnavailable
    case invalidBindingToken

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "OpenBurnBar Cloud is not available from the App Store yet. Try again in a moment."
        case .invalidBindingToken:
            return "OpenBurnBar could not prepare the Apple purchase token. Sign in again and retry."
        }
    }
}

// MARK: - Remote MCP data + listener (preserved from previous design)
//
// The Firestore-backed model + listener for connected MCP clients. Chrome
// underneath has switched to Aurora glass; the rest of the structure is
// untouched.

private struct MacRemoteMCPClientRecord: Identifiable, Hashable {
    let id: String
    let displayName: String
    let clientType: String
    let allowedScopes: [String]
    let grantMode: String
    let createdAt: Date?
    let lastUsedAt: Date?
    let revokedAt: Date?

    var isRevoked: Bool { revokedAt != nil }

    var displayType: String {
        clientType.isEmpty ? "generic MCP" : clientType
    }

    var scopeSummary: String {
        allowedScopes.isEmpty ? "No scopes recorded" : allowedScopes.sorted().joined(separator: ", ")
    }

    var modeSummary: String {
        switch grantMode {
        case "sealed_only": return "Sealed only"
        case "local_decrypt_shim": return "Local decrypt shim"
        case "remote_readable_explicit_opt_in": return "Remote readable opt-in"
        default: return grantMode.isEmpty ? "Local decrypt shim" : grantMode.replacingOccurrences(of: "_", with: " ")
        }
    }

    var activitySummary: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let lastUsedAt {
            return "Used \(formatter.localizedString(for: lastUsedAt, relativeTo: Date()))"
        }
        if let createdAt {
            return "Added \(formatter.localizedString(for: createdAt, relativeTo: Date()))"
        }
        return "Awaiting first use"
    }
}

@MainActor
private final class MacRemoteMCPClientStore: ObservableObject {
    @Published private(set) var clients: [MacRemoteMCPClientRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var revokingClientID: String?

    private nonisolated(unsafe) var listener: ListenerRegistration?
    private nonisolated(unsafe) var authHandle: AuthStateDidChangeListenerHandle?

    deinit {
        listener?.remove()
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
    }

    func startListening() {
        guard FirebaseApp.app() != nil else {
            clients = []
            error = "Cloud is not configured on this Mac."
            return
        }

        if authHandle == nil {
            authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                Task { @MainActor in
                    self?.restartListener(uid: user?.uid)
                }
            }
        }

        restartListener(uid: Auth.auth().currentUser?.uid)
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        isLoading = false
    }

    func revoke(_ client: MacRemoteMCPClientRecord) async {
        guard !client.isRevoked else { return }
        revokingClientID = client.id
        error = nil
        do {
            let callable = Functions.functions(region: "us-central1").httpsCallable("revokeRemoteMcpClient")
            _ = try await callable.call(["clientId": client.id])
        } catch {
            self.error = error.localizedDescription
        }
        revokingClientID = nil
    }

    private func restartListener(uid: String?) {
        listener?.remove()
        listener = nil
        error = nil
        guard let uid else {
            clients = []
            isLoading = false
            error = "Sign in to view connected MCP clients."
            return
        }

        isLoading = true
        listener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("remote_mcp_clients")
            .order(by: "updatedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoading = false
                    if let error {
                        self.clients = []
                        self.error = error.localizedDescription
                        return
                    }
                    self.clients = (snapshot?.documents ?? [])
                        .compactMap { Self.decode(documentID: $0.documentID, data: $0.data()) }
                        .sorted { lhs, rhs in
                            (lhs.lastUsedAt ?? lhs.createdAt ?? .distantPast) > (rhs.lastUsedAt ?? rhs.createdAt ?? .distantPast)
                        }
                }
            }
    }

    private static func decode(documentID: String, data: [String: Any]) -> MacRemoteMCPClientRecord {
        let clientID = (data["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientType = (data["clientType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = data["allowedScopes"] as? [String] ?? []
        let grantMode = (data["grantMode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MacRemoteMCPClientRecord(
            id: clientID?.isEmpty == false ? clientID! : documentID,
            displayName: displayName?.isEmpty == false ? displayName! : "OpenBurnBar MCP client",
            clientType: clientType ?? "",
            allowedScopes: scopes,
            grantMode: grantMode ?? "local_decrypt_shim",
            createdAt: date(from: data["createdAt"]),
            lastUsedAt: date(from: data["lastUsedAt"]),
            revokedAt: date(from: data["revokedAt"])
        )
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }
}

private struct MacRemoteMCPConnectedClientsSection: View {
    @ObservedObject var store: MacRemoteMCPClientStore
    @State private var pendingRevoke: MacRemoteMCPClientRecord?
    @State private var isConfirmingRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Connected clients", systemImage: "rectangle.connected.to.line.below")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.clients.isEmpty && !store.isLoading {
                Text("No MCP clients are connected yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } else {
                ForEach(store.clients) { client in
                    MacRemoteMCPClientRow(
                        client: client,
                        isRevoking: store.revokingClientID == client.id,
                        onRevoke: {
                            pendingRevoke = client
                            isConfirmingRevoke = true
                        }
                    )
                }
            }
        }
        .confirmationDialog("Revoke MCP client?", isPresented: $isConfirmingRevoke, titleVisibility: .visible) {
            if let pendingRevoke {
                Button("Revoke \(pendingRevoke.displayName)", role: .destructive) {
                    Task { await store.revoke(pendingRevoke) }
                }
            }
        } message: {
            if let pendingRevoke {
                Text("This immediately blocks \(pendingRevoke.displayName) and revokes its outstanding grants.")
            }
        }
    }
}

private struct MacRemoteMCPClientRow: View {
    let client: MacRemoteMCPClientRecord
    let isRevoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: client.isRevoked ? "xmark.seal.fill" : "checkmark.seal.fill")
                    .foregroundStyle(client.isRevoked ? DesignSystem.Colors.textMuted : DesignSystem.Colors.success)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(client.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("\(client.displayType) · \(client.modeSummary)")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text(client.scopeSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 8)

                if client.isRevoked {
                    Text("Revoked")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    Button(action: onRevoke) {
                        Group {
                            if isRevoking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.error.opacity(0.88))
                    .disabled(isRevoking)
                    .accessibilityLabel("Revoke \(client.displayName)")
                }
            }

            Text(client.activitySummary)
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    client.isRevoked
                        ? AnyShapeStyle(DesignSystem.Colors.border.opacity(0.50))
                        : AnyShapeStyle(DesignSystem.Colors.ember.opacity(0.30)),
                    lineWidth: 0.6
                )
        )
    }
}

#Preview("Cloud Store Settings (macOS)") {
    CloudStoreSettingsView()
        .frame(width: 720, height: 600)
}
