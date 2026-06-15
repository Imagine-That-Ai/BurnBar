import OSLog
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

// BurnBar Cloud Gateway settings section: status panels, setup wizard, pairing controls, client/approval lists, and gateway actions.
// Extracted from HermesSettingsView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension HermesSettingsView {

    var gatewayConnectionRow: some View {
        let onlineCount = gatewayStore.onlineClients.count
        let activeCount = gatewayStore.displayClients.count
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

    func gatewayConnectionSubtitle(activeCount: Int, onlineCount: Int) -> String {
        if onlineCount > 0 {
            let noun = onlineCount == 1 ? "client" : "clients"
            return "Official Hermes gateway · \(onlineCount) \(noun) online · works through BurnBar Cloud"
        }
        let noun = activeCount == 1 ? "client" : "clients"
        return "Official Hermes gateway · \(activeCount) paired \(noun) · waiting for gateway check-in"
    }

    var burnBarCloudGatewaySection: some View {
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

    var gatewayEntitlementStrip: some View {
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
    var gatewayPrimaryStatusPanel: some View {
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

    func gatewayOperationalStatusCard(
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

    func gatewayReplyHero(_ reply: HermesGatewayMessageRecord) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                HarnessModelBadge(
                    harness: AssistantRuntimeID.hermes.agentProvider,
                    model: gatewayReplyModelProvider(),
                    size: 46,
                    modelScale: 0.36,
                    ringStroke: MobileTheme.success
                )

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

            Text(HermesInlineMarkdown.attributedString(gatewayReplyBodyText(reply)))
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
    func gatewayReplyBodyText(
        _ reply: HermesGatewayMessageRecord,
        fallback: String = "Hermes sent a reply through BurnBar Cloud."
    ) -> String {
        // Delegate to the single source of truth shared with the chat thread so
        // the hero and the conversation never diverge: opened body, legacy
        // plaintext, attachment summary, or the calm jargon-free re-pair state
        // for a reply this device cannot open.
        reply.chatRenderText(emptyFallback: fallback)
    }

    func gatewayPendingHero(_ pending: HermesGatewayQueuedEvent) -> some View {
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

    var gatewaySetupWizard: some View {
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

    func gatewayWizardStep(
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

    func gatewayCommandRow(_ command: HermesGatewayWizardCommand) -> some View {
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

    var gatewayWizardStatusLabel: String {
        if !gatewayStore.onlineClients.isEmpty { return "Ready" }
        if !gatewayStore.activeClients.isEmpty { return "Paired" }
        if canonicalGatewayPairingCode != nil { return "Code ready" }
        return "Start here"
    }

    var gatewayWizardStatusIcon: String {
        if !gatewayStore.onlineClients.isEmpty { return "checkmark.seal.fill" }
        if !gatewayStore.activeClients.isEmpty { return "link.circle.fill" }
        if canonicalGatewayPairingCode != nil { return "keyboard.fill" }
        return "sparkles"
    }

    var gatewayWizardStatusColor: Color {
        if !gatewayStore.onlineClients.isEmpty { return MobileTheme.success }
        if !gatewayStore.activeClients.isEmpty { return MobileTheme.amber }
        if canonicalGatewayPairingCode != nil { return MobileTheme.hermesAureate }
        return MobileTheme.ember
    }

    func gatewayWizardStepColor(_ state: HermesGatewayWizardStepState) -> Color {
        switch state {
        case .complete: return MobileTheme.success
        case .current: return MobileTheme.ember
        case .upcoming: return MobileTheme.Colors.textMuted
        }
    }

    var gatewayPairingControls: some View {
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

    var gatewayPairingRevealButton: some View {
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

    var gatewayClientList: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack {
                label("Connected Clients")
                Spacer()
                if gatewayStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(gatewayStore.connectedClientCountText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }

            if gatewayStore.activeClients.isEmpty && !gatewayStore.isLoading {
                gatewayNotice("No Hermes clients yet.", icon: "tray", color: MobileTheme.Colors.textMuted)
            } else {
                if gatewayStore.hiddenDuplicateClientCount > 0 {
                    gatewayDuplicateClientsNotice
                }
                ForEach(gatewayStore.displayClients) { client in
                    gatewayClientRow(client)
                }
                gatewayReadinessNotice
            }
        }
    }

    var gatewayDuplicateClientsNotice: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.warning)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(gatewayStore.hiddenDuplicateClientCount) older reconnect \(gatewayStore.hiddenDuplicateClientCount == 1 ? "entry is" : "entries are") hidden.")
                    .font(.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    HapticBus.destructive()
                    showPruneGatewayClientsConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        if gatewayStore.isPruningStaleClients {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text("Remove older entries")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(MobileTheme.warning)
                .disabled(gatewayStore.isPruningStaleClients)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.warning.opacity(0.10))
        )
    }

    /// Inline approve/deny cards for armed oversight gates. This is a separate
    /// requestID namespace from the CLI-mission `ApprovalInboxStrip`, so it has
    /// its own focused surface and never touches that wiring.
    @ViewBuilder
    var gatewayApprovalsList: some View {
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

    func gatewayApprovalCard(_ approval: HermesGatewayApprovalRecord) -> some View {
        let isResponding = gatewayStore.isRespondingToApproval(approval)
        // MP-6: the end-to-end-encrypted action detail, bound to this gate by actionId
        // (the sealed payload's actionId == the agent confirm id), NOT the approval
        // document id (hga_<hash>) — those differ, so keying by approval.id would never
        // match and would permanently disable Approve.
        let sealedDetail = gatewayStore.sealedApprovalDetails[approval.actionId]
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
                    // MP-6: show the END-TO-END-ENCRYPTED detail (decrypted on this
                    // device, bound to this gate by actionId) for the action being
                    // approved — never a server-supplied free-text summary. Until the
                    // sealed detail arrives, Approve stays disabled (deny-by-default).
                    if let sealedDetail, !sealedDetail.isEmpty {
                        Text(sealedDetail)
                            .font(.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Encrypted action details are not available on this device yet. Approve from your Mac, or wait for the secured details to arrive.")
                            .font(.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                // MP-6: deny-by-default — Approve stays disabled until the matching
                // sealed detail has been decrypted on this device, so the user always
                // approves the action they actually saw end-to-end (informed consent).
                .disabled(isResponding || sealedDetail == nil)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.warning.opacity(0.10))
                .stroke(MobileTheme.warning.opacity(0.28), lineWidth: 0.75)
        )
    }

    var gatewayTestControls: some View {
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
    var gatewayReadinessNotice: some View {
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
    var gatewayDeliveryStatusCard: some View {
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
                Text(HermesInlineMarkdown.attributedString(gatewayReplyBodyText(reply, fallback: "Hermes sent a reply.")))
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

    func gatewayClientRow(_ client: HermesGatewayClientRecord) -> some View {
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
        .contentShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous))
        .onTapGesture {
            HapticBus.toggle()
            gatewayStore.selectClient(client)
            gatewayPrivacyClient = client
        }
    }

    func gatewayPrivacyState(for client: HermesGatewayClientRecord) -> HermesGatewayPrivacyState {
        HermesGatewayPrivacyState.resolve(
            client: client,
            keyChanged: gatewayStore.agentRelayKeyChanged(for: client)
        )
    }

    /// Oversight controls + runtime hints under a gateway client row:
    /// a Supervised/Autonomous segmented control, an optional agent version
    /// badge, and a transient "Switching…" indicator while a model swap lands.
    @ViewBuilder
    func gatewayClientOversightRow(_ client: HermesGatewayClientRecord) -> some View {
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
    func gatewayOversightToggle(_ client: HermesGatewayClientRecord) -> some View {
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

    func gatewayOversightChip(
        title: String,
        isOn: Bool,
        tint: Color,
        client: HermesGatewayClientRecord,
        mode: String
    ) -> some View {
        Button {
            guard !isOn else { return }
            HapticBus.toggle()
            Task { await gatewayStore.setOversight(clientId: client.id, mode: mode, targetClient: client) }
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

    var gatewaySection: some View {
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

    var gatewayOnlineClientCountText: String {
        let count = gatewayStore.onlineClients.count
        return count == 1 ? "1 gateway client is" : "\(count) gateway clients are"
    }

    var gatewayApprovalDisplayName: String {
        let identityName = authStore.currentIdentity?.displayName
            ?? authStore.currentIdentity?.email
            ?? "OpenBurnBar"
        return "\(identityName)'s iPhone"
    }

    var gatewayEntitlementText: String {
        guard authStore.state.isSignedIn else { return "Sign-in required" }
        guard let store = cloudSubscriptionStore else { return "Cloud checked on approval" }
        return store.isActive ? "BurnBar Cloud active" : "BurnBar Cloud or Cloud Pro required"
    }

    var gatewayEntitlementIcon: String {
        guard authStore.state.isSignedIn else { return "person.crop.circle.badge.exclamationmark" }
        guard let store = cloudSubscriptionStore else { return "cloud" }
        return store.isActive ? "checkmark.seal.fill" : "cloud.badge.exclamationmark"
    }

    var gatewayEntitlementColor: Color {
        guard authStore.state.isSignedIn else { return MobileTheme.warning }
        guard let store = cloudSubscriptionStore else { return MobileTheme.hermesAureate }
        return store.isActive ? MobileTheme.success : MobileTheme.amber
    }

    func gatewayNoticeColor(_ style: HermesGatewayNoticeStyle) -> Color {
        switch style {
        case .info: return MobileTheme.hermesAureate
        case .success: return MobileTheme.success
        case .warning: return MobileTheme.warning
        case .error: return MobileTheme.error
        }
    }

    func gatewayClientColor(_ client: HermesGatewayClientRecord) -> Color {
        guard client.isActive else { return MobileTheme.Colors.textMuted }
        if gatewayStore.agentRelayKeyChanged(for: client) { return MobileTheme.error }
        guard client.canSealToAgent else { return MobileTheme.warning }
        return gatewayStore.isOnline(client) ? MobileTheme.success : Color(hex: "8080ff")
    }

    func gatewayClientIcon(_ client: HermesGatewayClientRecord) -> String {
        guard client.isActive else { return "xmark.circle.fill" }
        if gatewayStore.agentRelayKeyChanged(for: client) { return "exclamationmark.shield.fill" }
        guard client.canSealToAgent else { return "exclamationmark.triangle.fill" }
        return gatewayStore.isOnline(client) ? "bolt.horizontal.circle.fill" : "moon.zzz.fill"
    }

    func gatewayClientSubtitle(_ client: HermesGatewayClientRecord) -> String {
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

    func gatewayRelativeDateText(_ raw: String?, relativeTo referenceDate: Date = Date()) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = Self.gatewayDate(from: raw) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: referenceDate)
        }
        return raw
    }

    func gatewayNotice(_ text: String, icon: String, color: Color) -> some View {
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

    func revoke(_ connection: HermesConnectionRecord) async {
        do {
            try await service.revokeConnection(connection)
        } catch {
            // Error surfaced via service.runtimeErrorText
        }
    }

    func approveGatewayCode() async {
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

    func applyPendingGatewayPairingDeepLink() {
        guard let code = HermesGatewayPairingDeepLink.consumePendingCode() else { return }
        applyGatewayPairingCode(code)
    }

    func applyGatewayPairingDeepLink(_ notification: Notification) {
        guard let code = HermesGatewayPairingDeepLink.code(from: notification) else { return }
        applyGatewayPairingCode(code)
        _ = HermesGatewayPairingDeepLink.consumePendingCode()
    }

    func applyGatewayPairingCode(_ code: String) {
        gatewayPairingCode = HermesGatewayPairingCodeFormatter.displayString(for: code)
        showGatewayAdditionalPairing = true
        gatewayStore.setNotice("Pairing code ready. Review it, then tap Connect Hermes.", style: .info)
    }

    func sendGatewayTestMessage() async {
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

    func copyGatewayCommand(_ command: HermesGatewayWizardCommand) {
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

    func gatewayReplyModelID() -> String {
        hermesGatewayNonBlank(service.selectedModelID)
            ?? hermesGatewayNonBlank(gatewayStore.runtimeModelId)
            ?? hermesGatewayNonBlank(service.selectedConnection.advertisedModel)
            ?? "hermes"
    }

    func gatewayReplyModelProvider() -> AgentProvider? {
        hermesGatewayReplyModelProvider(
            providerID: hermesGatewayNonBlank(gatewayStore.selectedClient?.runtimeProviderId),
            modelID: gatewayReplyModelID()
        )
    }
}
