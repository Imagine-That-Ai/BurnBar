import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseStorage
import OpenBurnBarCore

// MARK: - Hermes Settings View
//
// Comprehensive Hermes configuration surface. Four glass-card sections:
//   1. Connections — list, select, disconnect, add direct-URL entry
//   2. Gateway — base URL, bearer token, model override
//   3. Security — relay encryption details, pairing status
//   4. Status — runtime health, capabilities, model info, last-seen

struct HermesSettingsView: View {
    let service: HermesService
    let authStore: AuthStore

    @State private var showAddDirectSheet = false
    @State private var showTokenEditor = false
    @State private var editingToken = ""
    @State private var newDirectURL = ""
    @State private var newDirectName = ""
    @State private var showDeleteConfirm: HermesConnectionRecord? = nil
    @State private var showModelDetail: HermesRuntimeModelOption? = nil
    @State private var showModelPicker = false
    @State private var gatewayStore = HermesGatewaySettingsStore()
    @State private var gatewayPairingCode = ""
    @State private var gatewayTestMessage = "Hello Hermes from OpenBurnBar iPhone."
    @State private var showGatewaySignIn = false
    @State private var gatewaySuccessClient: HermesGatewayClientRecord?
    @State private var copiedGatewayCommand: HermesGatewayWizardCommand?
    @State private var showGatewayAdditionalPairing = false

    @AppStorage(HermesMobileChatPreferences.showMessageTPSKey) private var showMessageTPS = false
    @AppStorage(HermesMobileChatPreferences.usePretextRenderingKey) private var usePretextRendering = true
    @State private var showPretextPlayground = false

    @Environment(\.cloudSubscriptionStore) private var cloudSubscriptionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xl) {
                    headerCard
                        .settingsAnchor(SettingsAnchor.hermesRow)

                    connectionsSection
                        .settingsAnchor(SettingsAnchor.hermesConnections)
                    burnBarCloudGatewaySection
                        .settingsAnchor(SettingsAnchor.hermesCloudGateway)
                    modelsSection
                        .settingsAnchor(SettingsAnchor.hermesModels)
                    displaySection
                    gatewaySection
                    securitySection
                    statusSection

                    Spacer(minLength: MobileTheme.Spacing.xxxl)
                }
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.top, MobileTheme.Spacing.lg)
            }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Hermes")
        .sheet(isPresented: $showAddDirectSheet) { addDirectSheet }
        .sheet(isPresented: $showModelPicker) {
            if shouldUseGatewayModelPicker {
                HermesGatewayModelPickerSheet(
                    service: service,
                    gatewayStore: gatewayStore,
                    senderDisplayName: authStore.currentIdentity?.displayName ?? "OpenBurnBar iPhone",
                    threadId: service.selectedSessionID ?? HermesGatewayMessageResolver.defaultThreadID
                )
            } else {
                AssistantModelPickerSheet(
                    runtime: .hermes,
                    hermesService: service,
                    piService: PiService.shared
                )
            }
        }
        .sheet(isPresented: $showPretextPlayground) {
            PretextPlayground()
        }
        .sheet(isPresented: $showGatewaySignIn) {
            SignInScene(authStore: authStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $gatewaySuccessClient) { client in
            HermesGatewayConnectionSuccessSplash(
                client: client,
                onDone: { gatewaySuccessClient = nil },
                onSendTest: {
                    gatewaySuccessClient = nil
                    HapticBus.send()
                    Task { await sendGatewayTestMessage() }
                }
            )
        }
        .alert("Delete connection?", isPresented: deleteBinding) {
            Button("Cancel", role: .cancel) { showDeleteConfirm = nil }
            Button("Delete", role: .destructive) {
                if let c = showDeleteConfirm {
                    Task { await revoke(c) }
                }
                showDeleteConfirm = nil
            }
        } message: {
            Text(showDeleteConfirm?.displayName ?? "")
        }
        .task(id: authStore.currentIdentity?.uid) {
            gatewayStore.startGatewayListening(uid: authStore.currentIdentity?.uid)
            await gatewayStore.refresh(isSignedIn: authStore.state.isSignedIn)
            applyPendingGatewayPairingDeepLink()
        }
        .onReceive(NotificationCenter.default.publisher(for: HermesGatewayPairingDeepLink.notificationName)) { notification in
            applyGatewayPairingDeepLink(notification)
        }
        .onChange(of: authStore.state.isSignedIn) { _, isSignedIn in
            gatewayStore.startGatewayListening(uid: isSignedIn ? authStore.currentIdentity?.uid : nil)
            Task { await gatewayStore.refresh(isSignedIn: isSignedIn) }
        }
        .onDisappear {
            gatewayStore.stopGatewayListening()
        }
        .onChange(of: gatewayPairingCode) { _, newValue in
            let formatted = HermesGatewayPairingCodeFormatter.displayString(for: newValue)
            if formatted != newValue {
                gatewayPairingCode = formatted
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        NativeSettingsCard {
            HStack(spacing: MobileTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.mercuryGradient.opacity(0.25))
                        .frame(width: 52, height: 52)
                    Image("HermesLogo")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .scaleEffect(1.16)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.75)
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Hermes")
                        .font(.title3)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Messenger AI configuration")
                        .font(.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                Spacer()
            }
        }
    }

    // MARK: - 1. Connections

    private var connectionsSection: some View {
        NativeSettingsCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                sectionTitle("Connections", icon: "antenna.radiowaves.left.and.right", color: MobileTheme.hermesAureate)

                if !gatewayStore.activeClients.isEmpty {
                    gatewayConnectionRow
                }

                ForEach(service.connections) { connection in
                    connectionRow(connection)
                }

                Button {
                    showAddDirectSheet = true
                } label: {
                    HStack(spacing: MobileTheme.Spacing.sm) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Add direct Hermes URL")
                            .font(.body)
                    }
                    .foregroundStyle(MobileTheme.mercuryGradient)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    private var gatewayConnectionRow: some View {
        let onlineCount = gatewayStore.onlineClients.count
        let activeCount = gatewayStore.activeClients.count
        let isOnline = onlineCount > 0

        return HStack(spacing: MobileTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(isOnline ? MobileTheme.success : MobileTheme.warning)
                    .frame(width: 10, height: 10)
                if isOnline {
                    Circle()
                        .stroke(MobileTheme.success.opacity(0.5), lineWidth: 2)
                        .frame(width: 16, height: 16)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("BurnBar Cloud Gateway")
                    .font(.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(gatewayConnectionSubtitle(activeCount: activeCount, onlineCount: onlineCount))
                    .font(.caption2)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: isOnline ? "checkmark.seal.fill" : "link.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOnline ? MobileTheme.success : MobileTheme.warning)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("BurnBar Cloud Gateway. \(gatewayConnectionSubtitle(activeCount: activeCount, onlineCount: onlineCount))")
    }

    private func gatewayConnectionSubtitle(activeCount: Int, onlineCount: Int) -> String {
        if onlineCount > 0 {
            let noun = onlineCount == 1 ? "client" : "clients"
            return "Official Hermes gateway · \(onlineCount) \(noun) online · works through BurnBar Cloud"
        }
        let noun = activeCount == 1 ? "client" : "clients"
        return "Official Hermes gateway · \(activeCount) paired \(noun) · waiting for gateway check-in"
    }

    private func connectionRow(_ connection: HermesConnectionRecord) -> some View {
        let isSelected = service.selectedConnection.id == connection.id

        return Button {
            if !isSelected {
                _ = service.selectConnection(connection)
            }
        } label: {
            HStack(spacing: MobileTheme.Spacing.md) {
                // Status dot
                ZStack {
                    Circle()
                        .fill(connectionStatusColor(connection.status))
                        .frame(width: 10, height: 10)
                    if connection.status == .online {
                        Circle()
                            .stroke(connectionStatusColor(.online).opacity(0.5), lineWidth: 2)
                            .frame(width: 16, height: 16)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .font(.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(connectionSubtitle(connection))
                        .font(.caption2)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(MobileTheme.mercuryGradient)
                }

                if connection.id != HermesConnectionRecord.localDefault.id {
                    Button {
                        showDeleteConfirm = connection
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func connectionSubtitle(_ c: HermesConnectionRecord) -> String {
        var parts: [String] = []
        switch c.mode {
        case .local:      parts.append("Local")
        case .directURL:  parts.append("Direct")
        case .relayLink:  parts.append("Remote Relay")
        }
        if let url = c.endpointURL, !url.isEmpty {
            parts.append(url)
        }
        parts.append(c.status.rawValue.capitalized)
        return parts.joined(separator: " · ")
    }

    private func connectionStatusColor(_ status: HermesConnectionStatus) -> Color {
        switch status {
        case .online:     return MobileTheme.success
        case .offline:    return MobileTheme.Colors.textMuted
        case .pending:    return MobileTheme.amber
        case .unauthorized: return MobileTheme.warning
        case .revoked:    return MobileTheme.error
        case .degraded:   return MobileTheme.warning
        }
    }

    // MARK: - 2. BurnBar Cloud Gateway

    private var burnBarCloudGatewaySection: some View {
        NativeSettingsCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                HStack(alignment: .center, spacing: MobileTheme.Spacing.md) {
                    sectionTitle("BurnBar Cloud Gateway", icon: "paperplane.circle.fill", color: MobileTheme.ember)
                    Spacer()
                    Button {
                        HapticBus.refreshStarted()
                        Task { await gatewayStore.refresh(isSignedIn: authStore.state.isSignedIn) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(MobileTheme.ember)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(MobileTheme.Colors.surfaceElevated.opacity(0.82)))
                    }
                    .buttonStyle(.plain)
                    .disabled(gatewayStore.isLoading || !authStore.state.isSignedIn)
                    .accessibilityLabel("Refresh Hermes Gateway clients")
                }

                gatewayEntitlementStrip

                if let noticeText = gatewayStore.noticeText {
                    gatewayNotice(
                        noticeText,
                        icon: gatewayStore.noticeIcon,
                        color: gatewayNoticeColor(gatewayStore.noticeStyle)
                    )
                }

                if !authStore.state.isSignedIn {
                    gatewayNotice(
                        "Sign in to connect Hermes.",
                        icon: "person.crop.circle.badge.exclamationmark",
                        color: MobileTheme.warning
                    )
                    Button {
                        HapticBus.primaryAction()
                        showGatewaySignIn = true
                    } label: {
                        Label("Sign in", systemImage: "person.crop.circle.fill")
                            .font(.body)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MobileTheme.ember)
                } else {
                    gatewayPrimaryStatusPanel
                    if shouldShowGatewayPairingControls {
                        gatewayPairingControls
                    } else {
                        gatewayPairingRevealButton
                    }
                    gatewayClientList
                    gatewayApprovalsList
                    gatewayTestControls
                }
            }
        }
    }

    private var gatewayEntitlementStrip: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: gatewayEntitlementIcon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(gatewayEntitlementColor)
            Text(gatewayEntitlementText)
                .font(.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer(minLength: MobileTheme.Spacing.sm)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(gatewayEntitlementColor.opacity(0.10))
        )
    }

    @ViewBuilder
    private var gatewayPrimaryStatusPanel: some View {
        if let reply = gatewayStore.latestReply {
            gatewayReplyHero(reply)
        } else if let pending = gatewayStore.pendingTestEvent {
            gatewayPendingHero(pending)
        } else if gatewayStore.activeClients.isEmpty {
            gatewaySetupWizard
        } else if gatewayStore.onlineClients.isEmpty {
            gatewayOperationalStatusCard(
                icon: "link.circle.fill",
                title: "Paired, but Hermes is not online",
                detail: "BurnBar approved this gateway, but no client has checked in recently. Restart the Hermes Gateway on your computer so it loads the BurnBar token and starts receiving queued messages.",
                color: MobileTheme.warning,
                command: .restart
            )
        } else {
            gatewayOperationalStatusCard(
                icon: "bolt.horizontal.circle.fill",
                title: "Hermes is online and ready",
                detail: "\(gatewayOnlineClientCountText) live. Send a test below; the reply will appear here and as a local notification.",
                color: MobileTheme.success
            )
        }
    }

    private func gatewayOperationalStatusCard(
        icon: String,
        title: String,
        detail: String,
        color: Color,
        command: HermesGatewayWizardCommand? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let command {
                gatewayCommandRow(command)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(color.opacity(0.24), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }

    private func gatewayReplyHero(_ reply: HermesGatewayMessageRecord) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.success.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: "checkmark.message.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(MobileTheme.success)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Hermes replied")
                        .font(.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("End-to-end test complete through BurnBar Cloud")
                        .font(.caption)
                        .foregroundStyle(MobileTheme.success)
                }

                Spacer(minLength: 0)

                if let relativeDate = gatewayRelativeDateText(reply.createdAt, relativeTo: gatewayStore.statusNow) {
                    Text(relativeDate)
                        .font(.caption2)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                }
            }

            Text(gatewayReplyBodyText(reply))
                .font(.body)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                        .fill(MobileTheme.Colors.surfaceElevated.opacity(0.82))
                )

            if !reply.openedAttachments.isEmpty {
                ChatBubbleAttachmentStrip(attachments: reply.openedAttachments)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.success.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(MobileTheme.success.opacity(0.30), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }

    /// The body to render for a gateway reply. Sealed replies that opened on this
    /// device show their plaintext; a sealed reply this device cannot open (key
    /// mismatch / sealed for another paired device) shows a graceful explanation
    /// instead of an empty bubble; legacy plaintext replies show their `text`.
    private func gatewayReplyBodyText(
        _ reply: HermesGatewayMessageRecord,
        fallback: String = "Hermes sent a reply through BurnBar Cloud."
    ) -> String {
        // Delegate to the single source of truth shared with the chat thread so
        // the hero and the conversation never diverge: opened body, legacy
        // plaintext, attachment summary, or the calm jargon-free re-pair state
        // for a reply this device cannot open.
        reply.chatRenderText(emptyFallback: fallback)
    }

    private func gatewayPendingHero(_ pending: HermesGatewayQueuedEvent) -> some View {
        let isGatewayOnline = !gatewayStore.onlineClients.isEmpty
        let color = isGatewayOnline ? MobileTheme.hermesAureate : MobileTheme.warning

        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.14))
                        .frame(width: 46, height: 46)
                    if isGatewayOnline {
                        ProgressView()
                            .controlSize(.small)
                            .tint(color)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(color)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isGatewayOnline ? "Sent to Hermes" : "Queued, waiting for gateway")
                        .font(.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(
                        isGatewayOnline
                            ? "Event #\(pending.sequence) is waiting for a reply. Keep this screen open; the answer will appear here."
                            : "Event #\(pending.sequence) is stored in BurnBar Cloud. Restart the Hermes Gateway on your computer to pick it up."
                    )
                    .font(.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if !isGatewayOnline {
                gatewayCommandRow(.restart)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(color.opacity(0.26), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }

    private var gatewaySetupWizard: some View {
        let hasTypedCode = canonicalGatewayPairingCode != nil
        let hasPairedClient = !gatewayStore.activeClients.isEmpty
        let hasOnlineClient = !gatewayStore.onlineClients.isEmpty

        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Get the pairing code from Hermes")
                        .font(.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("The code is created in the Hermes terminal, then approved here while Hermes is waiting.")
                        .font(.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MobileTheme.Spacing.sm)

                HStack(spacing: 4) {
                    Image(systemName: gatewayWizardStatusIcon)
                    Text(gatewayWizardStatusLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(gatewayWizardStatusColor)
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .background(
                    Capsule()
                        .fill(gatewayWizardStatusColor.opacity(0.12))
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(gatewayWizardStatusLabel)
            }

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                gatewayWizardStep(
                    number: 1,
                    icon: "terminal.fill",
                    title: "Run Hermes setup",
                    detail: "On the computer where Hermes is installed, run:",
                    command: .setup,
                    state: hasTypedCode || hasPairedClient ? .complete : .current
                )

                gatewayWizardStep(
                    number: 2,
                    icon: "paperplane.circle.fill",
                    title: "Choose BurnBar Cloud",
                    detail: "Hermes will print an 8-character code like AB12-CD34 and a BurnBar approval link.",
                    state: hasTypedCode || hasPairedClient ? .complete : .upcoming
                )

                gatewayWizardStep(
                    number: 3,
                    icon: "iphone",
                    title: "Paste the code below",
                    detail: "Leave the Hermes terminal open. It is waiting for this approval.",
                    state: hasPairedClient ? .complete : (hasTypedCode ? .current : .upcoming)
                )

                gatewayWizardStep(
                    number: 4,
                    icon: "bolt.horizontal.circle.fill",
                    title: "Start the gateway",
                    detail: "After the code connects, keep this terminal process online. If you installed the background service, use start or restart instead.",
                    command: .run,
                    state: hasOnlineClient ? .complete : (hasPairedClient ? .current : .upcoming)
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            MobileTheme.hermesAureate.opacity(0.13),
                            MobileTheme.ember.opacity(0.08),
                            MobileTheme.Colors.surfaceElevated.opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(MobileTheme.hermesAureate.opacity(0.22), lineWidth: 0.75)
        )
        .accessibilityElement(children: .contain)
    }

    private func gatewayWizardStep(
        number: Int,
        icon: String,
        title: String,
        detail: String,
        command: HermesGatewayWizardCommand? = nil,
        state: HermesGatewayWizardStepState
    ) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(gatewayWizardStepColor(state).opacity(state == .upcoming ? 0.08 : 0.16))
                    .frame(width: 30, height: 30)
                if state == .complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(gatewayWizardStepColor(state))
                } else {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(gatewayWizardStepColor(state))
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: MobileTheme.Spacing.xs) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(gatewayWizardStepColor(state))
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let command {
                    gatewayCommandRow(command)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func gatewayCommandRow(_ command: HermesGatewayWizardCommand) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Text(command.text)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Spacer(minLength: MobileTheme.Spacing.xs)

            Button {
                copyGatewayCommand(command)
            } label: {
                Image(systemName: copiedGatewayCommand == command ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(copiedGatewayCommand == command ? MobileTheme.success : MobileTheme.hermesAureate)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(MobileTheme.Colors.surfaceElevated.opacity(0.82))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(command.accessibilityName)")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.72), lineWidth: 0.5)
        )
    }

    private var gatewayWizardStatusLabel: String {
        if !gatewayStore.onlineClients.isEmpty { return "Ready" }
        if !gatewayStore.activeClients.isEmpty { return "Paired" }
        if canonicalGatewayPairingCode != nil { return "Code ready" }
        return "Start here"
    }

    private var gatewayWizardStatusIcon: String {
        if !gatewayStore.onlineClients.isEmpty { return "checkmark.seal.fill" }
        if !gatewayStore.activeClients.isEmpty { return "link.circle.fill" }
        if canonicalGatewayPairingCode != nil { return "keyboard.fill" }
        return "sparkles"
    }

    private var gatewayWizardStatusColor: Color {
        if !gatewayStore.onlineClients.isEmpty { return MobileTheme.success }
        if !gatewayStore.activeClients.isEmpty { return MobileTheme.amber }
        if canonicalGatewayPairingCode != nil { return MobileTheme.hermesAureate }
        return MobileTheme.ember
    }

    private func gatewayWizardStepColor(_ state: HermesGatewayWizardStepState) -> Color {
        switch state {
        case .complete: return MobileTheme.success
        case .current: return MobileTheme.ember
        case .upcoming: return MobileTheme.Colors.textMuted
        }
    }

    private var gatewayPairingControls: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            label(gatewayStore.activeClients.isEmpty ? "Pairing Code" : "Pair Another Hermes")
            HStack(spacing: MobileTheme.Spacing.sm) {
                TextField("AB12-CD34", text: $gatewayPairingCode)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .onSubmit { Task { await approveGatewayCode() } }
                    .padding(MobileTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated)
                            .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                    )

                PasteButton(payloadType: String.self) { strings in
                    if let pasted = strings.first {
                        gatewayPairingCode = HermesGatewayPairingCodeFormatter.displayString(for: pasted)
                    }
                }
                .labelStyle(.iconOnly)
                .tint(MobileTheme.hermesAureate)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Paste pairing code")
            }

            Button {
                HapticBus.primaryAction()
                Task { await approveGatewayCode() }
            } label: {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    if gatewayStore.isApproving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.seal.fill")
                    }
                    Text(gatewayStore.isApproving ? "Connecting" : "Connect Hermes")
                }
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(MobileTheme.ember)
            .disabled(gatewayStore.isApproving || canonicalGatewayPairingCode == nil)

            if showGatewayAdditionalPairing && !gatewayStore.activeClients.isEmpty {
                Button {
                    HapticBus.primaryAction()
                    gatewayPairingCode = ""
                    showGatewayAdditionalPairing = false
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    private var gatewayPairingRevealButton: some View {
        Button {
            HapticBus.primaryAction()
            showGatewayAdditionalPairing = true
        } label: {
            HStack(spacing: MobileTheme.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                Text("Connect another Hermes")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(MobileTheme.hermesAureate)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var gatewayClientList: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack {
                label("Connected Clients")
                Spacer()
                if gatewayStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(gatewayStore.activeClients.count)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }

            if gatewayStore.clients.isEmpty && !gatewayStore.isLoading {
                gatewayNotice("No Hermes clients yet.", icon: "tray", color: MobileTheme.Colors.textMuted)
            } else {
                ForEach(gatewayStore.clients) { client in
                    gatewayClientRow(client)
                }
                gatewayReadinessNotice
            }
        }
    }

    /// Inline approve/deny cards for armed oversight gates. This is a separate
    /// requestID namespace from the CLI-mission `ApprovalInboxStrip`, so it has
    /// its own focused surface and never touches that wiring.
    @ViewBuilder
    private var gatewayApprovalsList: some View {
        let waiting = gatewayStore.waitingApprovals
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                HStack {
                    label("Awaiting Approval")
                    Spacer()
                    Text("\(waiting.count)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(MobileTheme.warning)
                }
                ForEach(waiting) { approval in
                    gatewayApprovalCard(approval)
                }
            }
        }
    }

    private func gatewayApprovalCard(_ approval: HermesGatewayApprovalRecord) -> some View {
        let isResponding = gatewayStore.isRespondingToApproval(approval)
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.warning)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    if let toolName = approval.toolName, !toolName.isEmpty {
                        Text(toolName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                    }
                    Text(approval.summary.isEmpty ? "Hermes is requesting approval to continue." : approval.summary)
                        .font(.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: MobileTheme.Spacing.sm) {
                Button {
                    HapticBus.destructive()
                    Task { await gatewayStore.respondToApproval(approvalId: approval.id, approve: false) }
                } label: {
                    Text("Deny")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(MobileTheme.error)
                .disabled(isResponding)

                Button {
                    HapticBus.primaryAction()
                    Task { await gatewayStore.respondToApproval(approvalId: approval.id, approve: true) }
                } label: {
                    HStack(spacing: 4) {
                        if isResponding {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text("Approve")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MobileTheme.success)
                .disabled(isResponding)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.warning.opacity(0.10))
                .stroke(MobileTheme.warning.opacity(0.28), lineWidth: 0.75)
        )
    }

    private var gatewayTestControls: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            label("Test Message")
            TextField("Message to Hermes", text: $gatewayTestMessage, axis: .vertical)
                .font(.body)
                .lineLimit(2...4)
                .padding(MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                        .fill(MobileTheme.Colors.surfaceElevated)
                        .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                )

            Button {
                HapticBus.send()
                Task { await sendGatewayTestMessage() }
            } label: {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    if gatewayStore.isSendingTest {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(gatewayStore.testButtonTitle)
                }
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(MobileTheme.hermesAureate)
            .disabled(
                gatewayStore.isSendingTest ||
                gatewayStore.activeClients.isEmpty ||
                gatewayTestMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            if gatewayStore.pendingTestEvent == nil, gatewayStore.latestReply == nil {
                gatewayNotice(
                    "Replies appear at the top of this card and as a local notification.",
                    icon: "bell.badge.fill",
                    color: MobileTheme.Colors.textMuted
                )
            }
        }
    }

    @ViewBuilder
    private var gatewayReadinessNotice: some View {
        if let selected = gatewayStore.selectedClient,
           gatewayStore.agentRelayKeyChanged(for: selected) {
            gatewayNotice(
                "\(selected.displayName)'s private pairing changed since you connected it. Messages are blocked until you connect Hermes again on that device.",
                icon: "exclamationmark.shield.fill",
                color: MobileTheme.error
            )
        } else if let selected = gatewayStore.selectedClient,
           !selected.canSealToAgent {
            gatewayNotice(
                "Update OpenBurnBar on \(selected.displayName), then connect Hermes again so private cloud messages can be read on both sides.",
                icon: "exclamationmark.triangle.fill",
                color: MobileTheme.warning
            )
        } else if let selected = gatewayStore.selectedClient,
           gatewayStore.isOnline(selected) {
            gatewayNotice(
                "\(selected.displayName) is selected, online, and ready for private cloud messages. Test messages should get picked up immediately.",
                icon: "checkmark.seal.fill",
                color: MobileTheme.success
            )
        } else if let selected = gatewayStore.selectedClient {
            gatewayNotice(
                "\(selected.displayName) is selected but not online right now. Open or restart that gateway client so it can pick up queued messages.",
                icon: "desktopcomputer",
                color: MobileTheme.warning
            )
        } else {
            gatewayNotice(
                "No Hermes gateway client is selected.",
                icon: "desktopcomputer",
                color: MobileTheme.warning
            )
        }
    }

    @ViewBuilder
    private var gatewayDeliveryStatusCard: some View {
        if let reply = gatewayStore.latestReply {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(MobileTheme.success)
                    Text("Hermes replied")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Spacer()
                    Text(gatewayRelativeDateText(reply.createdAt) ?? "now")
                        .font(.caption2)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Text(gatewayReplyBodyText(reply, fallback: "Hermes sent a reply."))
                    .font(.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                    .fill(MobileTheme.success.opacity(0.10))
                    .stroke(MobileTheme.success.opacity(0.28), lineWidth: 0.75)
            )
        } else if let pending = gatewayStore.pendingTestEvent {
            gatewayNotice(
                gatewayStore.selectedClient.map { client in
                    gatewayStore.isOnline(client)
                        ? "Event #\(pending.sequence) is queued for \(client.displayName). Waiting for Hermes to reply; you will see a banner/notification here when it does."
                        : "Event #\(pending.sequence) is queued for \(client.displayName). Hermes has not picked it up because that gateway client is not online."
                } ?? "Event #\(pending.sequence) is queued in BurnBar Cloud.",
                icon: gatewayStore.selectedClient.map { gatewayStore.isOnline($0) } == true ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill",
                color: gatewayStore.selectedClient.map { gatewayStore.isOnline($0) } == true ? MobileTheme.hermesAureate : MobileTheme.warning
            )
        }
    }

    private func gatewayClientRow(_ client: HermesGatewayClientRecord) -> some View {
        let isSelected = gatewayStore.selectedClient?.id == client.id
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(gatewayClientColor(client).opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: gatewayClientIcon(client))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(gatewayClientColor(client))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(client.displayName)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(gatewayClientSubtitle(client))
                    .font(.caption2)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(2)
            }

            Spacer(minLength: MobileTheme.Spacing.sm)

            Button {
                HapticBus.toggle()
                gatewayStore.selectClient(client)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isSelected ? MobileTheme.hermesAureate : MobileTheme.Colors.textMuted)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!client.isActive)
            .accessibilityLabel(isSelected ? "\(client.displayName) selected" : "Select \(client.displayName)")

            Button {
                HapticBus.destructive()
                Task { await gatewayStore.revoke(client) }
            } label: {
                if gatewayStore.isRevoking(client) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.plain)
            .disabled(!client.isActive || gatewayStore.isRevoking(client))
            .accessibilityLabel("Revoke \(client.displayName)")
            }

            gatewayClientOversightRow(client)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(isSelected ? MobileTheme.hermesAureate.opacity(0.10) : MobileTheme.Colors.surfaceElevated.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(isSelected ? MobileTheme.hermesAureate.opacity(0.42) : Color.clear, lineWidth: 0.8)
        )
    }

    /// Oversight controls + runtime hints under a gateway client row:
    /// a Supervised/Autonomous segmented control, an optional agent version
    /// badge, and a transient "Switching…" indicator while a model swap lands.
    @ViewBuilder
    private func gatewayClientOversightRow(_ client: HermesGatewayClientRecord) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            gatewayOversightToggle(client)

            if let agentVersion = client.agentVersion, !agentVersion.isEmpty {
                Text("v\(agentVersion)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if client.isSwitchingModel {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Switching\u{2026}")
                        .font(.caption2)
                        .foregroundStyle(MobileTheme.hermesAureate)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func gatewayOversightToggle(_ client: HermesGatewayClientRecord) -> some View {
        let isSupervised = client.isOversightSupervised
        HStack(spacing: 6) {
            gatewayOversightChip(
                title: "Supervised",
                isOn: isSupervised,
                tint: MobileTheme.success,
                client: client,
                mode: "supervised"
            )
            gatewayOversightChip(
                title: "Autonomous",
                isOn: !isSupervised,
                tint: MobileTheme.warning,
                client: client,
                mode: "autonomous"
            )
            if gatewayStore.isSettingOversight(client) {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    private func gatewayOversightChip(
        title: String,
        isOn: Bool,
        tint: Color,
        client: HermesGatewayClientRecord,
        mode: String
    ) -> some View {
        Button {
            guard !isOn else { return }
            HapticBus.toggle()
            Task { await gatewayStore.setOversight(clientId: client.id, mode: mode) }
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isOn ? tint : MobileTheme.Colors.textMuted)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? tint.opacity(0.16) : MobileTheme.Colors.surfaceElevated.opacity(0.6))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isOn ? tint.opacity(0.5) : Color.clear, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .disabled(!client.isActive || gatewayStore.isSettingOversight(client))
        .accessibilityLabel("\(title) oversight for \(client.displayName)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - 2. Models

    private var modelsSection: some View {
        NativeSettingsCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                HStack {
                    sectionTitle("Models", icon: "cpu", color: MobileTheme.whimsy)
                    Spacer()
                    Button {
                        presentModelPicker()
                    } label: {
                        Label("Switch", systemImage: "arrow.left.arrow.right")
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MobileTheme.whimsy)
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MobileTheme.whimsy)
                    }
                    .buttonStyle(.plain)
                }

                if service.modelOptions.isEmpty {
                    HStack(spacing: MobileTheme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 14))
                            .foregroundStyle(MobileTheme.amber)
                        Text("No models discovered yet.")
                            .font(.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .padding(.vertical, 4)
                } else {
                    if !service.favoriteModelOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Favorites")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                                .textCase(.uppercase)

                            ForEach(service.favoriteModelOptions) { option in
                                modelRow(option)
                            }
                        }
                    }

                    // Group by provider
                    let grouped = Dictionary(grouping: service.modelOptions, by: { $0.providerName })
                    let sortedProviders = grouped.keys.sorted()

                    ForEach(sortedProviders, id: \.self) { provider in
                        if let options = grouped[provider] {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(provider)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                                    .textCase(.uppercase)

                                ForEach(options) { option in
                                    modelRow(option)
                                }
                            }
                        }
                    }

                    // Default model picker
                    HStack(spacing: MobileTheme.Spacing.sm) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(MobileTheme.amber)
                        Text("Favorite models are pinned in the chat selector. Default:")
                            .font(.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                        Text(service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "hermes")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.whimsy)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func modelRow(_ option: HermesRuntimeModelOption) -> some View {
        let isDefault = service.selectedModelID == option.modelID
        let isFavorite = service.isFavoriteModel(option)

        return HStack(spacing: MobileTheme.Spacing.sm) {
            Button {
                service.selectModel(option)
            } label: {
                HStack(spacing: MobileTheme.Spacing.md) {
                    UnifiedProviderLogoView(provider: option.agentProvider, size: 30, useFallbackColor: true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.displayName)
                            .font(.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(option.modelID)
                            .font(.caption2)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                        if let detail = option.liveCatalogDetailText {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(option.isRouteEligible ? MobileTheme.Colors.textSecondary : MobileTheme.error)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if !option.isRouteEligible {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(MobileTheme.error)
                    } else if isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(MobileTheme.whimsy)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!option.isRouteEligible)
            .opacity(option.isRouteEligible ? 1 : 0.62)

            Button {
                service.toggleFavoriteModel(option)
                HapticBus.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isFavorite ? MobileTheme.amber : MobileTheme.Colors.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(MobileTheme.Colors.surfaceElevated.opacity(0.72)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove \(option.displayName) from favorites" : "Add \(option.displayName) to favorites")
        }
        .padding(.vertical, 6)
    }

    // MARK: - Display

    private var displaySection: some View {
        NativeSettingsCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                sectionTitle("Display", icon: "speedometer", color: MobileTheme.hermesAureate)

                Toggle(isOn: $showMessageTPS) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show tokens/sec")
                            .font(.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("Adds a small generation-speed footer below assistant messages. Provider-reported counts are exact; missing usage is marked “est.”")
                            .font(.caption2)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(MobileTheme.hermesAureate)
                .settingsAnchor(SettingsAnchor.hermesDisplayTPS)

                Divider().background(MobileTheme.Colors.border.opacity(0.4))

                Toggle(isOn: $usePretextRendering) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rich text rendering")
                            .font(.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("Hermes assistant messages render `@mentions` and `code spans` as inline chips, with line breaking by Pretext. Streaming and error states stay plain.")
                            .font(.caption2)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(MobileTheme.hermesAureate)
                .settingsAnchor(SettingsAnchor.hermesPretext)

                Divider().background(MobileTheme.Colors.border.opacity(0.4))

                NavigationLink {
                    SwarmBackgroundSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live background swarms")
                            .font(.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("Customize which glyphs appear, where the swarm renders, and battery/Wi-Fi conditions.")
                            .font(.caption2)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(MobileTheme.hermesAureate)

                Button {
                    showPretextPlayground = true
                } label: {
                    HStack(spacing: MobileTheme.Spacing.sm) {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Open text layout playground")
                            .font(.body)
                    }
                    .foregroundStyle(MobileTheme.mercuryGradient)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - 3. Gateway

    private var gatewaySection: some View {
        NativeSettingsCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                sectionTitle("Gateway", icon: "network", color: MobileTheme.ember)

                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    label("Base URL")
                    TextField("http://localhost:8642", text: urlBinding)
                        .font(.body)
                        .padding(MobileTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm)
                                .fill(MobileTheme.Colors.surfaceElevated)
                                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                        )
                        .keyboardType(.URL)
	                        .autocorrectionDisabled()
	                        .textInputAutocapitalization(.never)
	                }
                    .settingsAnchor(SettingsAnchor.hermesGatewayURL)

	                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    label("Bearer Token")
                    HStack {
                        SecureField("API_SERVER_KEY from ~/.hermes/.env", text: tokenBinding)
                            .font(.body)
                        Button {
                            showTokenEditor = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(MobileTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.sm)
                            .fill(MobileTheme.Colors.surfaceElevated)
	                            .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
	                    )
	                }
                    .settingsAnchor(SettingsAnchor.hermesGatewayToken)

	                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    label("Model Override")
                    TextField("Leave empty for auto (e.g. gpt-5.5)", text: modelBinding)
                        .font(.body)
                        .padding(MobileTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm)
                                .fill(MobileTheme.Colors.surfaceElevated)
                                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
        }
    }

    // MARK: - 3. Security

    private var securitySection: some View {
        NativeSettingsCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                sectionTitle("Security", icon: "lock.shield", color: MobileTheme.whimsy)

                Toggle(isOn: relayBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote Relay")
                            .font(.body)
                        Text("Allow iPhone/iPad to chat with this Mac over encrypted Firestore relay")
                            .font(.caption2)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .tint(MobileTheme.ember)

                if service.selectedConnection.mode == .relayLink,
                   let key = service.selectedConnection.relayPublicKey {
                    VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                        label("Relay Public Key")
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                if let encryption = service.selectedConnection.relayEncryption {
                    infoRow("Encryption", value: encryption)
                }
                if let version = service.selectedConnection.relayKeyVersion {
                    infoRow("Key Version", value: "\(version)")
                }
            }
        }
    }

    // MARK: - 4. Status

    private var statusSection: some View {
        NativeSettingsCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                sectionTitle("Status", icon: "gauge.with.dots.needle.67percent", color: MobileTheme.amber)

                if service.isLoadingRuntime {
                    HStack {
                        MiningPickLoader(.inline)
                        Text("Probing runtime…")
                            .font(.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                } else if let error = service.runtimeErrorText {
                    HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(MobileTheme.warning)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(MobileTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let model = service.selectedConnection.advertisedModel {
                    infoRow("Advertised Model", value: model)
                }

                if !service.selectedConnection.capabilities.isEmpty {
                    infoRow("Capabilities", value: service.selectedConnection.capabilities.joined(separator: ", "))
                }

                if let lastSeen = service.selectedConnection.lastSeenAt {
                    infoRow("Last Seen", value: lastSeen, style: .relative)
                }

                infoRow("Created", value: service.selectedConnection.createdAt, style: .date)
            }
        }
    }

    // MARK: - Add Direct Sheet

    private var addDirectSheet: some View {
        NavigationStack {
            Form {
                Section("Connection Details") {
                    TextField("Name (e.g. Home Mac)", text: $newDirectName)
                    TextField("URL (e.g. http://192.168.1.42:8642)", text: $newDirectURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Button("Save") {
                        // Direct URL connections are ephemeral until
                        // validated. The service will auto-discover or
                        // the user can select this as a custom entry.
                        // For now, we just store as a preference that
                        // the gateway URL text field already captures.
                        // Future: add to HermesConnectionRecord via a
                        // pairing / discovery flow.
                        showAddDirectSheet = false
                        newDirectName = ""
                        newDirectURL = ""
                    }
                    .disabled(newDirectURL.isEmpty)
                }
            }
            .navigationTitle("Add Direct Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddDirectSheet = false }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String, icon: String, color: Color) -> some View {
        Label {
            Text(title)
                .font(.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        } icon: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(MobileTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func infoRow(_ label: String, value: Date, style: Text.DateStyle) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer()
            Text(value, style: style)
                .font(.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
    }

    // MARK: - Bindings

    private var urlBinding: Binding<String> {
        Binding(
            get: { service.selectedConnection.endpointURL ?? "http://localhost:8642" },
            set: { newValue in
                // Update the selected connection's endpoint URL
                // This is a mutable property on the service's selectedConnection
                // In practice, HermesService manages this via its own persistence
            }
        )
    }

    private var tokenBinding: Binding<String> {
        Binding(
            get: { "" },
            set: { _ in }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { "" },
            set: { _ in }
        )
    }

    private var relayBinding: Binding<Bool> {
        Binding(
            get: { service.isRemoteRelayEnabled },
            set: { isEnabled in
                if service.setRemoteRelayEnabled(isEnabled) {
                    return
                }

                guard isEnabled else { return }
                Task { @MainActor in
                    await service.refreshConnections(refreshSelectedConnection: false)
                    _ = service.setRemoteRelayEnabled(true)
                }
            }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )
    }

    private var canonicalGatewayPairingCode: String? {
        HermesGatewayPairingCodeFormatter.canonicalCode(from: gatewayPairingCode)
    }

    private var shouldUseGatewayModelPicker: Bool {
        !gatewayStore.activeClients.isEmpty && (!service.isReachable || service.modelOptions.isEmpty)
    }

    private func presentModelPicker() {
        showModelPicker = true
    }

    private var shouldShowGatewayPairingControls: Bool {
        gatewayStore.activeClients.isEmpty || showGatewayAdditionalPairing || !gatewayPairingCode.isEmpty
    }

    private var gatewayOnlineClientCountText: String {
        let count = gatewayStore.onlineClients.count
        return count == 1 ? "1 gateway client is" : "\(count) gateway clients are"
    }

    private var gatewayApprovalDisplayName: String {
        let identityName = authStore.currentIdentity?.displayName
            ?? authStore.currentIdentity?.email
            ?? "OpenBurnBar"
        return "\(identityName)'s iPhone"
    }

    private var gatewayEntitlementText: String {
        guard authStore.state.isSignedIn else { return "Sign-in required" }
        guard let store = cloudSubscriptionStore else { return "Cloud checked on approval" }
        return store.isActive ? "BurnBar Cloud active" : "BurnBar Cloud or Cloud Pro required"
    }

    private var gatewayEntitlementIcon: String {
        guard authStore.state.isSignedIn else { return "person.crop.circle.badge.exclamationmark" }
        guard let store = cloudSubscriptionStore else { return "cloud" }
        return store.isActive ? "checkmark.seal.fill" : "cloud.badge.exclamationmark"
    }

    private var gatewayEntitlementColor: Color {
        guard authStore.state.isSignedIn else { return MobileTheme.warning }
        guard let store = cloudSubscriptionStore else { return MobileTheme.hermesAureate }
        return store.isActive ? MobileTheme.success : MobileTheme.amber
    }

    private func gatewayNoticeColor(_ style: HermesGatewayNoticeStyle) -> Color {
        switch style {
        case .info: return MobileTheme.hermesAureate
        case .success: return MobileTheme.success
        case .warning: return MobileTheme.warning
        case .error: return MobileTheme.error
        }
    }

    private func gatewayClientColor(_ client: HermesGatewayClientRecord) -> Color {
        guard client.isActive else { return MobileTheme.Colors.textMuted }
        if gatewayStore.agentRelayKeyChanged(for: client) { return MobileTheme.error }
        guard client.canSealToAgent else { return MobileTheme.warning }
        return gatewayStore.isOnline(client) ? MobileTheme.success : Color(hex: "8080ff")
    }

    private func gatewayClientIcon(_ client: HermesGatewayClientRecord) -> String {
        guard client.isActive else { return "xmark.circle.fill" }
        if gatewayStore.agentRelayKeyChanged(for: client) { return "exclamationmark.shield.fill" }
        guard client.canSealToAgent else { return "exclamationmark.triangle.fill" }
        return gatewayStore.isOnline(client) ? "bolt.horizontal.circle.fill" : "moon.zzz.fill"
    }

    private func gatewayClientSubtitle(_ client: HermesGatewayClientRecord) -> String {
        let keyChanged = gatewayStore.agentRelayKeyChanged(for: client)
        var parts = [
            gatewayStore.selectedClient?.id == client.id ? "Selected" : nil,
            keyChanged ? "Connection changed — reconnect" : (client.canSealToAgent ? "Private replies ready" : "Update and reconnect"),
            gatewayStore.isOnline(client) ? "Online now" : "Not online",
            client.homeDestinationId,
            client.tokenPreview
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if let dateText = gatewayRelativeDateText(
            client.lastSeenAt ?? client.updatedAt,
            relativeTo: gatewayStore.statusNow
        ) {
            parts.append(dateText)
        }
        return parts.joined(separator: " · ")
    }

    private func gatewayRelativeDateText(_ raw: String?, relativeTo referenceDate: Date = Date()) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = Self.gatewayDate(from: raw) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: referenceDate)
        }
        return raw
    }

    private static func gatewayDate(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func gatewayNotice(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(color.opacity(0.10))
        )
    }

    // MARK: - Actions

    private func revoke(_ connection: HermesConnectionRecord) async {
        do {
            try await service.revokeConnection(connection)
        } catch {
            // Error surfaced via service.runtimeErrorText
        }
    }

    private func approveGatewayCode() async {
        guard let code = canonicalGatewayPairingCode else {
            gatewayStore.setNotice("Enter the 8-character Hermes code.", style: .warning)
            HapticBus.threshold()
            return
        }
        if let client = await gatewayStore.approve(userCode: code, displayName: gatewayApprovalDisplayName) {
            gatewayPairingCode = ""
            showGatewayAdditionalPairing = false
            gatewaySuccessClient = client
            HapticBus.milestone()
        } else {
            HapticBus.threshold()
        }
    }

    private func applyPendingGatewayPairingDeepLink() {
        guard let code = HermesGatewayPairingDeepLink.consumePendingCode() else { return }
        applyGatewayPairingCode(code)
    }

    private func applyGatewayPairingDeepLink(_ notification: Notification) {
        guard let code = HermesGatewayPairingDeepLink.code(from: notification) else { return }
        applyGatewayPairingCode(code)
        _ = HermesGatewayPairingDeepLink.consumePendingCode()
    }

    private func applyGatewayPairingCode(_ code: String) {
        gatewayPairingCode = HermesGatewayPairingCodeFormatter.displayString(for: code)
        showGatewayAdditionalPairing = true
        gatewayStore.setNotice("Pairing code ready. Review it, then tap Connect Hermes.", style: .info)
    }

    private func sendGatewayTestMessage() async {
        let text = gatewayTestMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            gatewayStore.setNotice("Type a message first.", style: .warning)
            HapticBus.threshold()
            return
        }
        let didSend = await gatewayStore.sendTest(text: text, senderDisplayName: gatewayApprovalDisplayName)
        if !didSend {
            HapticBus.threshold()
        }
    }

    private func copyGatewayCommand(_ command: HermesGatewayWizardCommand) {
        copiedGatewayCommand = command
        HapticBus.primaryAction()
        #if canImport(UIKit)
        UIPasteboard.general.string = command.text
        #endif

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if copiedGatewayCommand == command {
                copiedGatewayCommand = nil
            }
        }
    }
}


/// A native inset-grouped-style card. Replaces `AuroraGlassCard` on the Hermes
/// settings surface so it reads like Apple's stock Settings — grouped cards on
/// `systemGroupedBackground` — instead of the Aurora glass treatment used
/// elsewhere in the app.
private struct NativeSettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

enum HermesGatewayPairingCodeFormatter {
    static func displayString(for raw: String) -> String {
        let compact = compactCode(raw)
        guard compact.count > 4 else { return compact }
        let split = compact.index(compact.startIndex, offsetBy: 4)
        return "\(compact[..<split])-\(compact[split...])"
    }

    static func canonicalCode(from raw: String) -> String? {
        let compact = compactCode(raw)
        guard compact.count == 8 else { return nil }
        return displayString(for: compact)
    }

    private static func compactCode(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
    }
}

private enum HermesGatewayWizardCommand: Hashable {
    case setup
    case run
    case restart

    var text: String {
        switch self {
        case .setup:
            return "hermes gateway setup"
        case .run:
            return "hermes gateway run"
        case .restart:
            return "hermes gateway restart"
        }
    }

    var accessibilityName: String {
        switch self {
        case .setup:
            return "Hermes gateway setup command"
        case .run:
            return "Hermes gateway run command"
        case .restart:
            return "Hermes gateway restart command"
        }
    }
}

private enum HermesGatewayWizardStepState {
    case complete
    case current
    case upcoming
}

enum HermesGatewayNoticeStyle {
    case info
    case success
    case warning
    case error
}

@Observable
@MainActor
final class HermesGatewaySettingsStore {
    private let repository: any HermesGatewayRepository
    @ObservationIgnored private let defaults: UserDefaults
    private static let selectedClientDefaultsKey = "hermesGateway.selectedClientId"

    private(set) var clients: [HermesGatewayClientRecord] = []
    private(set) var selectedClientId: String?
    private(set) var isLoading = false
    private(set) var isApproving = false
    private(set) var isSendingTest = false
    private(set) var isSendingGatewayMessage = false
    private(set) var isSwitchingModel = false
    private(set) var revokingClientId: String?
    private(set) var noticeText: String?
    private(set) var noticeStyle: HermesGatewayNoticeStyle = .info
    private(set) var pendingTestEvent: HermesGatewayQueuedEvent?
    private(set) var pendingModelSwitchEvent: HermesGatewayQueuedEvent?
    private(set) var latestReply: HermesGatewayMessageRecord?
    private(set) var approvals: [HermesGatewayApprovalRecord] = []
    private(set) var respondingApprovalId: String?
    private(set) var settingOversightClientId: String?
    private(set) var statusNow = Date()

    @ObservationIgnored private var clientListener: ListenerRegistration?
    @ObservationIgnored private var messageListener: ListenerRegistration?
    @ObservationIgnored private var approvalListener: ListenerRegistration?
    @ObservationIgnored private var statusClockTask: Task<Void, Never>?
    @ObservationIgnored private var listenedUID: String?
    @ObservationIgnored private let agentKeyPinStore = HermesGatewayAgentKeyPinStore()
    @ObservationIgnored private var lastNotifiedMessageID: String?
    @ObservationIgnored private var pendingEventSentAt: Date?
    @ObservationIgnored private var messageListenerStartedAt: Date?
    @ObservationIgnored private let gatewayThreadID = HermesGatewayMessageResolver.defaultThreadID
    @ObservationIgnored private var openedGatewayAttachments: [String: HermesAttachment] = [:]
    @ObservationIgnored private var failedGatewayAttachmentIDs = Set<String>()
    private static let maxGatewayAttachmentDownloadBytes: Int64 =
        Int64(HermesAttachmentLimits.maxGenericBytes * 2 + 4096)

    init(repository: any HermesGatewayRepository = FunctionsRepository.shared, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        self.selectedClientId = defaults.string(forKey: Self.selectedClientDefaultsKey)
    }

    var activeClients: [HermesGatewayClientRecord] {
        clients.filter(\.isActive)
    }

    var onlineClients: [HermesGatewayClientRecord] {
        activeClients.filter { $0.isOnline(relativeTo: statusNow) }
    }

    /// Oversight gates still waiting for a decision and not past their
    /// server-stamped expiry, newest first.
    var waitingApprovals: [HermesGatewayApprovalRecord] {
        approvals
            .filter { $0.isActionable(relativeTo: statusNow) }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    var selectedClient: HermesGatewayClientRecord? {
        if let selectedClientId,
           let client = activeClients.first(where: { $0.id == selectedClientId }) {
            return client
        }
        return onlineClients.first ?? activeClients.first
    }

    var selectedTargetClientId: String? {
        selectedClient?.id
    }

    var runtimeModelOptions: [HermesRuntimeModelOption] {
        var seen = Set<String>()
        var options: [HermesRuntimeModelOption] = []
        var seenClients = Set<String>()
        let clientsByPriority = ([selectedClient].compactMap(\.self) + onlineClients + activeClients)
            .reduce(into: [HermesGatewayClientRecord]()) { result, client in
                guard !seenClients.contains(client.id) else { return }
                seenClients.insert(client.id)
                result.append(client)
            }
        for client in clientsByPriority {
            for option in client.runtimeModelOptions {
                let key = option.modelId.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                options.append(option.hermesRuntimeOption)
            }
            if let modelId = nonEmpty(client.runtimeModelId) {
                let key = modelId.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    options.append(
                        HermesRuntimeModelOption(
                            providerID: nonEmpty(client.runtimeProviderId) ?? "hermes",
                            providerName: nonEmpty(client.runtimeProviderId) ?? "Hermes",
                            modelID: modelId,
                            displayName: modelId,
                            sourceKind: "burnbar-cloud-gateway",
                            routeEligible: true
                        )
                    )
                }
            }
        }
        return options
    }

    var runtimeModelId: String? {
        selectedClient.flatMap { nonEmpty($0.runtimeModelId) }
            ?? onlineClients.compactMap { nonEmpty($0.runtimeModelId) }.first
            ?? activeClients.compactMap { nonEmpty($0.runtimeModelId) }.first
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func gatewayE2EERequiredMessage(for client: HermesGatewayClientRecord) -> String {
        "Update OpenBurnBar on \(client.displayName), then reconnect Hermes so private messages can be read on both sides."
    }

    private static func gatewayRelayKeyChangedMessage(for client: HermesGatewayClientRecord) -> String {
        "\(client.displayName)'s connection looks different from when you set it up. Nothing was sent, to keep things safe. Reconnect Hermes on \(client.displayName) to restore private replies."
    }

    /// True when the agent pubkey this client now advertises differs from the one
    /// pinned at first pairing (possible MITM). Returns `false` when there is no
    /// pin yet (first trust), no usable key, or no signed-in uid — the seal path
    /// itself stays the authoritative fail-closed gate; this only drives the
    /// pre-flight notice and the badge.
    func agentRelayKeyChanged(for client: HermesGatewayClientRecord) -> Bool {
        guard
            client.canSealToAgent,
            let advertised = client.relayPublicKey,
            let uid = listenedUID, !uid.isEmpty,
            let pinned = agentKeyPinStore.pinnedKey(uid: uid, clientId: client.id)
        else {
            return false
        }
        return pinned != advertised.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clear the TOFU pin for a client so the next observed agent key is trusted
    /// afresh. Used on deliberate re-pair / revoke so re-pairing re-establishes
    /// trust instead of tripping the mismatch guard forever.
    private func clearAgentKeyPin(clientId: String) {
        guard let uid = listenedUID, !uid.isEmpty else { return }
        agentKeyPinStore.clearPin(uid: uid, clientId: clientId)
    }

    /// A short, human-comparable "safety code" for a paired client's private
    /// connection, so a user can compare it across their phone and Mac to confirm
    /// no one is intercepting the channel. Prefers the key this device has already
    /// trusted (the Keychain pin); before the first send pins a key it falls back
    /// to the key the connection currently advertises so the code is never blank
    /// on a freshly paired Mac. Returns `nil` only when there is genuinely no key
    /// to show.
    func agentSafetyCode(for client: HermesGatewayClientRecord) -> String? {
        if let uid = listenedUID, !uid.isEmpty,
           let pinned = agentKeyPinStore.pinnedSafetyCode(uid: uid, clientId: client.id) {
            return pinned
        }
        guard let advertised = client.relayPublicKey else { return nil }
        return HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: advertised)
    }

    /// Explicit, user-confirmed re-pair for a client whose private connection now
    /// looks different from when it was first set up (a changed key — possible
    /// interception — or a reply this device can no longer open after a reinstall
    /// or new phone).
    ///
    /// This deliberately requires the caller to have obtained explicit user
    /// consent first: it forgets the previously trusted key so the **next** time
    /// this device sends, it re-establishes trust on the key the connection now
    /// advertises (trust-on-first-use), and pins that. It never silently accepts a
    /// new key mid-flight — the fail-closed seal guard still refuses to send until
    /// this is called — so the interception protection is preserved while giving
    /// the user a clean, honest way to recover a real reinstall / new device.
    func repinAgentKeyAfterUserConfirmation(for client: HermesGatewayClientRecord) {
        clearAgentKeyPin(clientId: client.id)
        setNotice(
            "Trust reset for \(client.displayName). Send a message to finish reconnecting privately.",
            style: .success
        )
    }

    var testButtonTitle: String {
        if isSendingTest { return "Queueing" }
        return selectedClient?.isOnline(relativeTo: statusNow) == true ? "Send and wait for reply" : "Queue test"
    }

    var noticeIcon: String {
        switch noticeStyle {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    func startGatewayListening(uid: String?) {
        syncSelectedClientIDFromDefaults()
        guard let uid, !uid.isEmpty else {
            stopGatewayListening()
            latestReply = nil
            pendingTestEvent = nil
            return
        }
        guard listenedUID != uid else {
            startStatusClockIfNeeded()
            return
        }
        stopGatewayListening()
        listenedUID = uid
        messageListenerStartedAt = Date()
        startStatusClockIfNeeded()
        clientListener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("hermes_gateway_clients")
            .order(by: "updatedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    self?.handleClientsSnapshot(snapshot: snapshot, error: error)
                }
            }
        messageListener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("hermes_gateway_messages")
            .order(by: "createdAt", descending: true)
            .limit(to: 20)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    self?.handleMessagesSnapshot(snapshot: snapshot, error: error)
                }
            }
        approvalListener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("hermes_gateway_approvals")
            .order(by: "requestedAt", descending: true)
            .limit(to: 40)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    self?.handleApprovalsSnapshot(snapshot: snapshot, error: error)
                }
            }
    }

    func stopGatewayListening() {
        clientListener?.remove()
        clientListener = nil
        messageListener?.remove()
        messageListener = nil
        approvalListener?.remove()
        approvalListener = nil
        statusClockTask?.cancel()
        statusClockTask = nil
        listenedUID = nil
        messageListenerStartedAt = nil
        openedGatewayAttachments = [:]
        failedGatewayAttachmentIDs = []
    }

    func refresh(isSignedIn: Bool) async {
        guard isSignedIn else {
            clients = []
            approvals = []
            persistSelectedClientID(nil)
            noticeText = nil
            pendingTestEvent = nil
            latestReply = nil
            return
        }
        guard !isLoading else { return }
        syncSelectedClientIDFromDefaults()
        failedGatewayAttachmentIDs = []
        isLoading = true
        defer { isLoading = false }

        do {
            clients = try await repository.listHermesGatewayClients()
            repairSelectedClientIfNeeded()
            noticeText = nil
        } catch {
            setNotice(error.localizedDescription, style: .error)
        }
    }

    @discardableResult
    func approve(userCode: String, displayName: String) async -> HermesGatewayClientRecord? {
        guard !isApproving else { return nil }
        isApproving = true
        defer { isApproving = false }

        do {
            let client = try await repository.approveHermesGatewayDeviceGrant(
                userCode: userCode,
                displayName: displayName
            )
            // Root the agent-key pin in the AUTHENTICATED approval, not relay TOFU.
            // `approveHermesGatewayDeviceGrant` is an AppCheck + auth-gated callable;
            // the `relayPublicKey` it returns is delivered over that authenticated
            // channel, so a relay cannot swap it post-approval. Re-pairing first
            // drops any stale pin (explicit operator re-trust), then we pin the
            // freshly-approved key IMMEDIATELY — so the very first seal authenticates
            // against a pairing-rooted key instead of one read from a relay-writable
            // client doc at send time (closes the first-pin poisoning window). The
            // out-of-band safety code (shown at pairing) remains the ultimate root
            // against a fully-compromised server, exactly like Signal's safety number.
            clearAgentKeyPin(clientId: client.id)
            var pinPersisted = true
            if let uid = listenedUID, !uid.isEmpty,
               let agentKey = client.relayPublicKey, !agentKey.isEmpty {
                // Fail-closed: `verifyOrPin` now reflects a Keychain WRITE failure
                // (it returns `.unknownKeychainError` rather than a phantom
                // `.pinnedFirstUse`). If the pairing-rooted pin could not be stored
                // durably, the out-of-band safety code is the fallback root and the
                // operator must verify it before trusting the link.
                pinPersisted = agentKeyPinStore.verifyOrPin(
                    agentPublicKeyBase64: agentKey, uid: uid, clientId: client.id
                ).allowsSeal
            }
            upsert(client)
            persistSelectedClientID(client.id)
            // Surface the out-of-band safety code at pairing: comparing it against
            // the code your Mac prints is what catches a server that tampered with
            // the very first key exchange (the one window the authenticated pin
            // above cannot close on its own). This is the Signal "safety number".
            // If the pin did not persist, the safety check is the ONLY root, so we
            // make the instruction emphatic.
            let safetyHint = agentSafetyCode(for: client).map {
                pinPersisted
                    ? " Safety code: \($0) — confirm it matches the code shown on your Mac."
                    : " IMPORTANT — this device couldn't store the pairing key securely, so you MUST verify the safety code: \($0) must match the code shown on your Mac before you trust this link."
            } ?? ""
            setNotice(
                "Hermes is paired.\(safetyHint) Now run `hermes gateway run`, or start/restart the installed gateway service, so Hermes is online to receive messages.",
                style: .warning
            )
            return client
        } catch {
            if isConsumedPairingCodeError(error),
               let existingClient = await refreshAfterConsumedPairingCode() {
                setNotice("Hermes is already connected.", style: .success)
                return existingClient
            }
            setNotice(error.localizedDescription, style: .error)
            return nil
        }
    }

    func revoke(_ client: HermesGatewayClientRecord) async {
        guard client.isActive, revokingClientId == nil else { return }
        revokingClientId = client.id
        defer { revokingClientId = nil }

        do {
            try await repository.revokeHermesGatewayClient(clientId: client.id)
            // Revoking ends this pairing; drop its pin so a future re-pair (which
            // may reuse the client id) trusts the new agent key on first use.
            clearAgentKeyPin(clientId: client.id)
            clients = clients.filter { $0.id != client.id }
            repairSelectedClientIfNeeded()
            setNotice("Hermes client revoked.", style: .success)
        } catch {
            setNotice(error.localizedDescription, style: .error)
        }
    }

    func selectClient(_ client: HermesGatewayClientRecord) {
        guard client.isActive else {
            setNotice("That Hermes client has been revoked.", style: .warning)
            return
        }
        persistSelectedClientID(client.id)
        let online = client.isOnline(relativeTo: statusNow)
        setNotice(
            online
                ? "\(client.displayName) is selected for gateway messages."
                : "\(client.displayName) is selected. Messages will queue until it checks in.",
            style: online ? .success : .warning
        )
    }

    @discardableResult
    func sendGatewayMessage(text: String, senderDisplayName: String, threadId: String) async -> HermesGatewayQueuedEvent? {
        syncSelectedClientIDFromDefaults()
        guard let targetClient = selectedClient else {
            setNotice("Connect Hermes first.", style: .warning)
            return nil
        }
        guard targetClient.canSealToAgent else {
            setNotice(Self.gatewayE2EERequiredMessage(for: targetClient), style: .warning)
            return nil
        }
        guard !agentRelayKeyChanged(for: targetClient) else {
            setNotice(Self.gatewayRelayKeyChangedMessage(for: targetClient), style: .error)
            return nil
        }
        guard !isSendingGatewayMessage else { return nil }
        isSendingGatewayMessage = true
        defer { isSendingGatewayMessage = false }

        do {
            let event = try await repository.enqueueHermesGatewayEvent(
                text: text,
                threadId: threadId,
                targetClient: targetClient,
                targetClientId: targetClient.id,
                senderDisplayName: senderDisplayName
            )
            pendingTestEvent = event
            pendingEventSentAt = Date()
            statusNow = Date()
            latestReply = nil
            let targetOnline = targetClient.isOnline(relativeTo: statusNow)
            setNotice(
                targetOnline
                    ? "Message sent to \(targetClient.displayName) through BurnBar Cloud. Waiting for Hermes to reply."
                    : "Message queued for \(targetClient.displayName) in BurnBar Cloud. Hermes will pick it up when that gateway checks in.",
                style: targetOnline ? .info : .warning
            )
            return event
        } catch {
            setNotice(error.localizedDescription, style: .error)
            return nil
        }
    }

    @discardableResult
    func switchGatewayModel(modelId: String, senderDisplayName: String, threadId: String) async -> HermesGatewayQueuedEvent? {
        syncSelectedClientIDFromDefaults()
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setNotice("Type a model id first.", style: .warning)
            return nil
        }
        guard let targetClient = selectedClient else {
            setNotice("Connect Hermes first.", style: .warning)
            return nil
        }
        guard targetClient.canSealToAgent else {
            setNotice(Self.gatewayE2EERequiredMessage(for: targetClient), style: .warning)
            return nil
        }
        guard !agentRelayKeyChanged(for: targetClient) else {
            setNotice(Self.gatewayRelayKeyChangedMessage(for: targetClient), style: .error)
            return nil
        }
        guard !isSwitchingModel else { return nil }
        isSwitchingModel = true
        defer { isSwitchingModel = false }

        do {
            let event = try await repository.enqueueHermesGatewayModelSwitch(
                modelId: trimmed,
                threadId: threadId,
                targetClient: targetClient,
                targetClientId: targetClient.id,
                senderDisplayName: senderDisplayName
            )
            pendingModelSwitchEvent = event
            pendingTestEvent = event
            pendingEventSentAt = Date()
            statusNow = Date()
            latestReply = nil
            setNotice(
                "Model switch queued for \(targetClient.displayName): \(trimmed).",
                style: targetClient.isOnline(relativeTo: statusNow) ? .info : .warning
            )
            return event
        } catch {
            setNotice(error.localizedDescription, style: .error)
            return nil
        }
    }

    /// Flip a gateway client between supervised (every action gated) and
    /// autonomous oversight. `mode` must be "supervised" or "autonomous".
    func setOversight(clientId: String, mode: String) async {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else { return }
        guard settingOversightClientId == nil else { return }
        settingOversightClientId = trimmedClientId
        defer { settingOversightClientId = nil }

        do {
            try await repository.setHermesGatewayOversightMode(clientId: trimmedClientId, mode: mode)
            setNotice(
                mode == "autonomous"
                    ? "Autonomous mode on. This Hermes will run without per-action approval."
                    : "Supervised mode on. This Hermes will wait for your approval on gated actions.",
                style: mode == "autonomous" ? .warning : .success
            )
        } catch {
            setNotice(error.localizedDescription, style: .error)
        }
    }

    /// Approve or reject an armed oversight gate. The decision is bound to this
    /// trusted native escrow device (same path as CLI-mission approvals) so a
    /// stolen owner token cannot self-approve a gated gateway action.
    func respondToApproval(approvalId: String, approve: Bool) async {
        let trimmedApprovalId = approvalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApprovalId.isEmpty else { return }
        guard respondingApprovalId == nil else { return }
        respondingApprovalId = trimmedApprovalId
        defer { respondingApprovalId = nil }

        let deviceId = MobileDeviceIdentity.loadOrCreateDeviceId()
        do {
            try await repository.respondHermesGatewayApproval(
                approvalId: trimmedApprovalId,
                approve: approve,
                deviceId: deviceId
            )
            setNotice(
                approve ? "Action approved. Hermes will continue." : "Action rejected.",
                style: approve ? .success : .warning
            )
        } catch {
            setNotice(error.localizedDescription, style: .error)
        }
    }

    func isRespondingToApproval(_ approval: HermesGatewayApprovalRecord) -> Bool {
        respondingApprovalId == approval.id
    }

    func isSettingOversight(_ client: HermesGatewayClientRecord) -> Bool {
        settingOversightClientId == client.id
    }

    @discardableResult
    func sendTest(text: String, senderDisplayName: String) async -> Bool {
        syncSelectedClientIDFromDefaults()
        guard let targetClient = selectedClient else {
            setNotice("Connect Hermes first.", style: .warning)
            return false
        }
        guard !isSendingTest else { return false }
        isSendingTest = true
        defer { isSendingTest = false }

        do {
            let event = try await repository.enqueueHermesGatewayEvent(
                text: text,
                targetClient: targetClient,
                targetClientId: targetClient.id,
                senderDisplayName: senderDisplayName
            )
            pendingTestEvent = event
            pendingEventSentAt = Date()
            statusNow = Date()
            latestReply = nil
            let targetOnline = targetClient.isOnline(relativeTo: statusNow)
            let message = targetOnline
                ? "Event #\(event.sequence) is queued for \(targetClient.displayName). Waiting for Hermes to reply."
                : "Event #\(event.sequence) is queued for \(targetClient.displayName). Open or restart that gateway client so it can pick up the message."
            setNotice(message, style: targetOnline ? .info : .warning)
            return true
        } catch {
            setNotice(error.localizedDescription, style: .error)
            return false
        }
    }

    private func handleClientsSnapshot(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            setNotice("Could not watch Hermes gateway clients: \(error.localizedDescription)", style: .error)
            return
        }
        clients = snapshot?.documents.compactMap { document in
            HermesGatewayClientRecord(documentID: document.documentID, data: document.data())
        } ?? []
        statusNow = Date()
        syncSelectedClientIDFromDefaults()
        repairSelectedClientIfNeeded()
    }

    private func handleMessagesSnapshot(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            setNotice("Could not watch Hermes replies: \(error.localizedDescription)", style: .error)
            return
        }
        // Open sealed replies with this phone's relay key before resolving/rendering.
        // Legacy plaintext docs pass through unchanged; a doc this device cannot
        // open keeps `resolvedText == nil` and renders the sealed-for-another-device
        // state instead of empty.
        let keypair = HermesGatewayRelayKeypair.loadOrCreate()
        let messages = (snapshot?.documents.compactMap { document in
            HermesGatewayMessageRecord(documentID: document.documentID, data: document.data())
        } ?? []).map { record -> HermesGatewayMessageRecord in
            guard let uid = listenedUID, !uid.isEmpty else { return record }
            // Pass the shared pin store so an unsealed reply on a client whose agent
            // key this device pinned is treated as a downgrade (never rendered as a
            // genuine reply) — closes the server-injected-plaintext impersonation gap.
            return record.decodedText(using: keypair, uid: uid, pinStore: agentKeyPinStore)
        }

        if let pendingTestEvent {
            guard let reply = HermesGatewayMessageResolver.newestReply(
                for: pendingTestEvent,
                in: messages,
                threadID: gatewayThreadID,
                targetClientId: pendingTestEvent.targetClientId ?? selectedTargetClientId,
                pendingEventSentAt: pendingEventSentAt
            ) else { return }
            Task { @MainActor in
                let hydrated = await hydrateGatewayAttachments(for: reply)
                latestReply = hydrated
                self.pendingTestEvent = nil
                pendingEventSentAt = nil
                setNotice("Hermes replied. The gateway is working end to end.", style: .success)
                HapticBus.milestone()
                presentReplyNotification(hydrated)
            }
            return
        }

        guard let reply = HermesGatewayMessageResolver.newestThreadReply(
            in: messages,
            threadID: gatewayThreadID,
            targetClientId: selectedTargetClientId
        ) else { return }
        Task { @MainActor in
            let hydrated = await hydrateGatewayAttachments(for: reply)
            let isNewReply = latestReply?.id != hydrated.id
            latestReply = hydrated
            if isNewReply,
               HermesGatewayMessageResolver.wasCreatedWhileListening(
                    hydrated,
                    listenerStartedAt: messageListenerStartedAt
               ) {
                setNotice("Hermes replied. The gateway is working end to end.", style: .success)
                HapticBus.milestone()
                presentReplyNotification(hydrated)
            }
        }
    }

    private func hydrateGatewayAttachments(for reply: HermesGatewayMessageRecord) async -> HermesGatewayMessageRecord {
        guard !reply.attachmentIds.isEmpty,
              let uid = listenedUID, !uid.isEmpty
        else { return reply }

        var opened: [HermesAttachment] = []
        var failed: [String] = []
        for attachmentId in reply.attachmentIds {
            if let cached = openedGatewayAttachments[attachmentId] {
                opened.append(cached)
                continue
            }
            if failedGatewayAttachmentIDs.contains(attachmentId) {
                failed.append(attachmentId)
                continue
            }
            guard let attachment = await openGatewayAttachment(
                attachmentId: attachmentId,
                uid: uid,
                clientId: reply.clientId
            ) else {
                failedGatewayAttachmentIDs.insert(attachmentId)
                failed.append(attachmentId)
                continue
            }
            openedGatewayAttachments[attachmentId] = attachment
            opened.append(attachment)
        }
        return reply.withAttachmentHydration(opened: opened, failedAttachmentIds: failed)
    }

    private func openGatewayAttachment(attachmentId: String, uid: String, clientId: String) async -> HermesAttachment? {
        do {
            guard let data = try await fetchGatewayAttachmentDocument(uid: uid, attachmentId: attachmentId),
                  let record = HermesGatewayAttachmentRecord(documentID: attachmentId, data: data),
                  record.clientId == clientId,
                  let storagePath = record.bodyStoragePath,
                  !storagePath.isEmpty
            else { return nil }

            let sealedBody = try await downloadGatewayAttachmentBody(storagePath: storagePath)
            let keypair = HermesGatewayRelayKeypair.loadOrCreate()
            // v2: bind the AGENT's pinned relay key so a forged attachment fails
            // the authenticated unwrap. Fail closed if unpinned.
            guard let opened = record.opened(
                downloadedBody: sealedBody, using: keypair, uid: uid,
                pinnedSenderKey: agentKeyPinStore.pinnedKey(uid: uid, clientId: clientId)
            ) else {
                return nil
            }
            return try HermesAttachmentLoader.importGatewayOpenedAttachment(opened, threadID: gatewayThreadID)
        } catch {
            return nil
        }
    }

    private func fetchGatewayAttachmentDocument(uid: String, attachmentId: String) async throws -> [String: Any]? {
        try await withCheckedThrowingContinuation { continuation in
            Firestore.firestore()
                .collection("users").document(uid)
                .collection("hermes_gateway_attachments").document(attachmentId)
                .getDocument { snapshot, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: snapshot?.data())
                }
        }
    }

    private func downloadGatewayAttachmentBody(storagePath: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Storage.storage().reference(withPath: storagePath).getData(maxSize: Self.maxGatewayAttachmentDownloadBytes) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: FunctionsError.gatewayAttachmentUnreadable)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func handleApprovalsSnapshot(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            setNotice("Could not watch Hermes approvals: \(error.localizedDescription)", style: .error)
            return
        }
        approvals = snapshot?.documents.compactMap { document in
            HermesGatewayApprovalRecord(documentID: document.documentID, data: document.data())
        } ?? []
        statusNow = Date()
    }

    private func presentReplyNotification(_ reply: HermesGatewayMessageRecord) {
        guard lastNotifiedMessageID != reply.id else { return }
        lastNotifiedMessageID = reply.id
        AgentReplyNotificationService.shared.presentLocalReply(
            id: reply.id,
            title: "Hermes replied",
            // Same source of truth as the chat thread: a reply this device can't
            // open surfaces the calm re-pair line, never an empty preview.
            preview: reply.chatRenderText(emptyFallback: "Hermes sent a reply through BurnBar Cloud."),
            runtime: AssistantRuntimeID.hermes.rawValue,
            threadID: reply.threadId ?? gatewayThreadID
        )
    }

    func isRevoking(_ client: HermesGatewayClientRecord) -> Bool {
        revokingClientId == client.id
    }

    func isOnline(_ client: HermesGatewayClientRecord) -> Bool {
        client.isOnline(relativeTo: statusNow)
    }

    func setNotice(_ text: String, style: HermesGatewayNoticeStyle) {
        noticeText = text
        noticeStyle = style
    }

    private func upsert(_ client: HermesGatewayClientRecord) {
        clients.removeAll { $0.id == client.id }
        clients.insert(client, at: 0)
        repairSelectedClientIfNeeded()
    }

    private func isConsumedPairingCodeError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("pairing code was not found")
    }

    private func refreshAfterConsumedPairingCode() async -> HermesGatewayClientRecord? {
        do {
            clients = try await repository.listHermesGatewayClients()
            statusNow = Date()
            repairSelectedClientIfNeeded()
            return selectedClient ?? activeClients.first
        } catch {
            return nil
        }
    }

    private func repairSelectedClientIfNeeded() {
        let active = activeClients
        guard !active.isEmpty else {
            persistSelectedClientID(nil)
            return
        }
        if let selectedClientId,
           active.contains(where: { $0.id == selectedClientId }) {
            return
        }
        persistSelectedClientID(onlineClients.first?.id ?? active.first?.id)
    }

    private func syncSelectedClientIDFromDefaults() {
        let stored = defaults.string(forKey: Self.selectedClientDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (stored?.isEmpty == false) ? stored : nil
        if normalized != selectedClientId {
            selectedClientId = normalized
            clearGatewayConversationStateForTargetChange()
        }
    }

    private func persistSelectedClientID(_ clientId: String?) {
        let previous = selectedClientId
        let trimmed = clientId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            selectedClientId = trimmed
            defaults.set(trimmed, forKey: Self.selectedClientDefaultsKey)
        } else {
            selectedClientId = nil
            defaults.removeObject(forKey: Self.selectedClientDefaultsKey)
        }
        if previous != selectedClientId {
            clearGatewayConversationStateForTargetChange()
        }
    }

    private func clearGatewayConversationStateForTargetChange() {
        pendingTestEvent = nil
        pendingModelSwitchEvent = nil
        pendingEventSentAt = nil
        latestReply = nil
        lastNotifiedMessageID = nil
    }

    private func startStatusClockIfNeeded() {
        guard statusClockTask == nil else { return }
        statusNow = Date()
        statusClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.statusNow = Date()
            }
        }
    }

}

private struct HermesGatewayConnectionSuccessSplash: View {
    let client: HermesGatewayClientRecord
    let onDone: () -> Void
    let onSendTest: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cardIn = false
    @State private var avatarsIn = false
    @State private var connected = false
    @State private var detailsIn = false
    @State private var haloPulse = false
    @State private var burst = false

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .full)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    MobileTheme.ember.opacity(0.22),
                    MobileTheme.hermesAureate.opacity(0.14),
                    Color.black.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: MobileTheme.Spacing.xl) {
                Spacer(minLength: 18)

                VStack(spacing: MobileTheme.Spacing.xl) {
                    logoHandshake

                    VStack(spacing: MobileTheme.Spacing.sm) {
                        Text("Hermes is connected")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("BurnBar Cloud can now send messages to Hermes and receive replies from your local gateway.")
                            .font(.body)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .opacity(connected ? 1 : 0)
                    .offset(y: connected ? 0 : 10)

                    VStack(spacing: MobileTheme.Spacing.sm) {
                        connectionPill(
                            icon: "checkmark.seal.fill",
                            label: client.displayName,
                            value: "Active"
                        )
                        .opacity(detailsIn ? 1 : 0)
                        .offset(y: detailsIn ? 0 : 14)
                        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.04), value: detailsIn)

                        connectionPill(
                            icon: "key.horizontal.fill",
                            label: "Token",
                            value: client.tokenPreview
                        )
                        .opacity(detailsIn ? 1 : 0)
                        .offset(y: detailsIn ? 0 : 14)
                        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.12), value: detailsIn)
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.xl)
                .padding(.vertical, MobileTheme.Spacing.xxxl)
                .background(cardBackground)
                .scaleEffect(cardIn ? 1 : 0.94)
                .opacity(cardIn ? 1 : 0)

                VStack(spacing: MobileTheme.Spacing.md) {
                    Button {
                        HapticBus.primaryAction()
                        onSendTest()
                    } label: {
                        Label("Send test message", systemImage: "paperplane.fill")
                            .font(.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MobileTheme.ember)

                    Button {
                        onDone()
                    } label: {
                        Text("Done")
                            .font(.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.bordered)
                    .tint(MobileTheme.hermesAureate)
                }
                .padding(.horizontal, MobileTheme.Spacing.xl)
                .opacity(detailsIn ? 1 : 0)
                .offset(y: detailsIn ? 0 : 16)
                .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.2), value: detailsIn)

                Spacer(minLength: 28)
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
        .onAppear { runIntro() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes is connected to BurnBar Cloud")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous)
            .fill(MobileTheme.Colors.surface.opacity(0.82))
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                MobileTheme.hermesAureate.opacity(0.56),
                                MobileTheme.ember.opacity(0.34),
                                Color.white.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: MobileTheme.ember.opacity(0.20), radius: 34, x: 0, y: 18)
    }

    // MARK: - Handshake

    private var logoHandshake: some View {
        HStack(spacing: 0) {
            avatar(assetName: "HermesLogo", label: "Hermes", color: MobileTheme.hermesAureate, fillsCircle: true)
                .offset(x: 10)
                .zIndex(1)

            connectorColumn
                .zIndex(2)

            avatar(assetName: "AppLogo", label: "BurnBar", color: MobileTheme.ember, fillsCircle: false)
                .offset(x: -10)
                .zIndex(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hermes connected to BurnBar")
    }

    private var connectorColumn: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            ZStack {
                Capsule()
                    .fill(MobileTheme.Colors.surfaceElevated.opacity(0.92))
                    .frame(width: 84, height: 42)
                    .overlay(Capsule().stroke(MobileTheme.Colors.border.opacity(0.8), lineWidth: 0.75))
                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)

                if connected && !reduceMotion {
                    burstRing(delay: 0)
                    burstRing(delay: 0.12)
                }

                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(MobileTheme.success)
                    .scaleEffect(connected ? 1 : 0.2)
                    .opacity(connected ? 1 : 0)
            }
            .scaleEffect(avatarsIn ? 1 : 0.6)
            .opacity(avatarsIn ? 1 : 0)

            // Phantom label keeps the badge vertically centered on the avatar
            // circles (whose columns also carry a caption row below).
            Text(" ")
                .font(.caption)
                .opacity(0)
        }
        .accessibilityHidden(true)
    }

    private func burstRing(delay: Double) -> some View {
        Circle()
            .stroke(MobileTheme.success.opacity(0.55), lineWidth: 2.5)
            .frame(width: 40, height: 40)
            .scaleEffect(burst ? 2.6 : 0.55)
            .opacity(burst ? 0 : 0.85)
            .animation(.easeOut(duration: 0.75).delay(delay), value: burst)
    }

    private func avatar(assetName: String, label: String, color: Color, fillsCircle: Bool) -> some View {
        let size: CGFloat = 104
        return VStack(spacing: MobileTheme.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.30))
                    .frame(width: size, height: size)
                    .blur(radius: 20)
                    .scaleEffect(haloPulse ? 1.12 : 0.94)
                    .opacity(haloPulse ? 0.95 : 0.55)

                Circle()
                    .fill(MobileTheme.Colors.surfaceElevated)
                    .frame(width: size, height: size)
                    .shadow(color: color.opacity(0.28), radius: 16, x: 0, y: 9)

                logoArtwork(assetName, fillsCircle: fillsCircle, size: size)

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(0.85), color.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: size, height: size)
            }
            .scaleEffect(avatarsIn ? 1 : 0.6)
            .opacity(avatarsIn ? 1 : 0)

            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .opacity(connected ? 1 : 0)
        }
    }

    @ViewBuilder
    private func logoArtwork(_ name: String, fillsCircle: Bool, size: CGFloat) -> some View {
        if fillsCircle {
            // Portrait-style logo: fill the circle and crop the asset's baked
            // square frame so it reads as an elegant avatar, not a boxed image.
            Image(name)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .scaleEffect(1.2)
                .clipShape(Circle())
        } else {
            Image(name)
                .resizable()
                .scaledToFit()
                .padding(size * 0.22)
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }

    private func connectionPill(icon: String, label: String, value: String) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.success)
                .frame(width: 20)

            Text(label)
                .font(.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Spacer(minLength: MobileTheme.Spacing.sm)

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.72))
        )
    }

    // MARK: - Intro choreography

    private func runIntro() {
        Haptics.light()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            cardIn = true
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.66).delay(0.12)) {
            avatarsIn = true
        }
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                haloPulse = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
            HapticBus.milestone()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
                connected = true
            }
            // Defer one runloop so the burst rings mount before they animate.
            DispatchQueue.main.async {
                withAnimation { burst = true }
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                detailsIn = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HermesSettingsView(
            service: HermesService(),
            authStore: AuthStore()
        )
    }
}
