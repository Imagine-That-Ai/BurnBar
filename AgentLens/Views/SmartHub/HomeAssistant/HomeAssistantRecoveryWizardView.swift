import AppKit
import SwiftUI

// MARK: - Home Assistant Recovery Wizard View
//
// 7-step polished wizard. The model owns the state machine; this view
// only routes `model.step` into a per-step subview. Each subview is a
// private struct so the wizard remains diff-friendly.
//
// Visual identity:
//   - Aurora background (DesignSystem.Colors.background)
//   - Whimsy + Ember accent — same gradient as the Cast wizard so the
//     two flows read as a connected family
//   - Sidebar lists steps with state icons; body owns the active step
//   - Footer: Cancel + step-aware primary CTA

struct HomeAssistantRecoveryWizardView: View {

    @Bindable var model: HomeAssistantRecoveryWizardModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .background(DesignSystem.Colors.surface)
                .overlay(
                    Rectangle()
                        .fill(DesignSystem.Colors.borderSubtle)
                        .frame(width: 0.5),
                    alignment: .trailing
                )

            VStack(spacing: 0) {
                ZStack {
                    body(for: model.step)
                        .padding(.horizontal, DesignSystem.Spacing.xxl)
                        .padding(.vertical, DesignSystem.Spacing.xl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(stepKey(model.step))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity
                        ))
                }
                .background(DesignSystem.Colors.background)

                footer
            }
        }
        .frame(width: 560, height: 680)
        .animation(DesignSystem.Animation.standard, value: stepKey(model.step))
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "house.lodge.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.whimsy)
                    Text("Home Assistant")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                Text("Recovery Setup")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.xl)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(WizardStage.orderedStages, id: \.self) { stage in
                    sidebarRow(stage: stage)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)

            Spacer()

            sidebarHelp
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.lg)
        }
    }

    private func sidebarRow(stage: WizardStage) -> some View {
        let active = currentStage == stage
        let completed = stageOrdinal(currentStage) > stageOrdinal(stage)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(active
                          ? DesignSystem.Colors.primaryGradient
                          : LinearGradient(colors: [DesignSystem.Colors.surfaceElevated, DesignSystem.Colors.surfaceElevated],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(active ? Color.clear : DesignSystem.Colors.border, lineWidth: 0.5)
                    )
                if completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.success)
                } else {
                    Text("\(stage.ordinal)")
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(active ? .white : DesignSystem.Colors.textMuted)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(active ? .semibold : .regular)
                    .foregroundStyle(active ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                Text(stage.subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? DesignSystem.Colors.surfaceElevated.opacity(0.8) : .clear)
        )
        .animation(DesignSystem.Animation.gentle, value: active)
    }

    @ViewBuilder
    private var sidebarHelp: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Why this exists")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text("Some Nest Hubs block direct Cast from a Mac. Home Assistant runs on your network and can recover the Cast for you.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
    }

    // MARK: - Body routing

    @ViewBuilder
    private func body(for step: HomeAssistantRecoveryWizardModel.Step) -> some View {
        switch step {
        case .why:
            WhyStep()
        case .findInstance:
            FindInstanceStep(model: model)
        case .probing(let url):
            ProbingStep(url: url)
        case .connectToken(let url, let version):
            ConnectTokenStep(model: model, url: url, version: version)
        case .validatingToken(let url):
            BusyStep(
                title: "Checking your access token…",
                message: "Talking to \(url.host ?? "Home Assistant")."
            )
        case .pickDisplay(_, let players):
            PickDisplayStep(
                model: model,
                players: players,
                suggestedName: model.installedConfig?.mediaPlayerFriendlyName
                    ?? (model.existingConfig?.mediaPlayerFriendlyName ?? "")
            )
        case .loadingDisplays:
            BusyStep(
                title: "Asking Home Assistant about your displays…",
                message: "We're finding every cast-capable media player on your instance."
            )
        case .installRecovery(_, let entityID, let friendlyName):
            ConfirmInstallStep(
                model: model,
                entityID: entityID,
                friendlyName: friendlyName
            )
        case .installing(_, _, let friendlyName):
            BusyStep(
                title: "Installing the recovery automation…",
                message: "Writing the OpenBurnBar Smart Display Recovery automation for \(friendlyName)."
            )
        case .liveTest(let config):
            LiveTestStep(model: model, config: config)
        case .testing:
            BusyStep(
                title: "Testing the webhook…",
                message: "We're calling Home Assistant exactly the way OpenBurnBar will when native Cast fails."
            )
        case .done(let config):
            DoneStep(config: config, onClose: onClose)
        case .blueprintIntro(let url):
            BlueprintStep(model: model, baseURL: url)
        case .failed(let message, let recoverable, let previous):
            FailedStep(
                message: message,
                recoverable: recoverable,
                previous: previous,
                onRetry: { model.retryFromFailure() },
                onClose: onClose,
                onSwitchToBlueprint: { model.chooseBlueprintFallback() }
            )
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Button("Cancel") { onClose() }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .keyboardShortcut(.cancelAction)
            Spacer()
            footerStatusText
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.surface)
        .overlay(
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    @ViewBuilder
    private var footerStatusText: some View {
        if let version = model.detectedVersion {
            Text("Connected to Home Assistant \(version)")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        } else {
            Text("OpenBurnBar Smart Display Recovery")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    // MARK: - Stage helpers

    private var currentStage: WizardStage {
        switch model.step {
        case .why: return .why
        case .findInstance, .probing: return .find
        case .connectToken, .validatingToken: return .connect
        case .loadingDisplays, .pickDisplay: return .pickDisplay
        case .installRecovery, .installing, .blueprintIntro: return .install
        case .liveTest, .testing: return .test
        case .done: return .done
        case .failed(_, _, let previous):
            switch previous {
            case .findInstance: return .find
            case .connectToken: return .connect
            case .pickDisplay: return .pickDisplay
            case .installRecovery: return .install
            case .liveTest: return .test
            case .blueprint: return .install
            }
        }
    }
}

// MARK: - Stage labels

private enum WizardStage: Int, Hashable {
    case why
    case find
    case connect
    case pickDisplay
    case install
    case test
    case done

    static var orderedStages: [WizardStage] {
        [.why, .find, .connect, .pickDisplay, .install, .test, .done]
    }

    var ordinal: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .why: return "Why this helps"
        case .find: return "Find your HA"
        case .connect: return "Connect"
        case .pickDisplay: return "Pick display"
        case .install: return "Install"
        case .test: return "Test"
        case .done: return "Done"
        }
    }

    var subtitle: String {
        switch self {
        case .why: return "60 seconds"
        case .find: return "URL or hostname"
        case .connect: return "Long-lived token"
        case .pickDisplay: return "Choose entity"
        case .install: return "REST or blueprint"
        case .test: return "Verify webhook"
        case .done: return "Recovery armed"
        }
    }
}

private func stageOrdinal(_ stage: WizardStage) -> Int { stage.rawValue }

// MARK: - Step views

private struct WhyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HeroBadge(icon: "shield.lefthalf.filled.badge.checkmark", tint: .ember)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Why we're connecting Home Assistant")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Some Google Nest Hubs accept Cast traffic only from devices on the same WiFi subnet. When that happens, OpenBurnBar's native Cast can see the Hub but can't connect to it.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                BulletRow(icon: "wifi", title: "Reach your Hub from anywhere it's reachable",
                          subtitle: "Home Assistant runs on your network. If anything can reach your Hub, it can — and it'll cast the OpenBurnBar dashboard for you.")
                BulletRow(icon: "key.fill", title: "Your token stays on this Mac",
                          subtitle: "We store your access token in the macOS keychain. It never goes to OpenBurnBar's servers, never to iCloud, never to your iPhone.")
                BulletRow(icon: "wand.and.stars", title: "No YAML",
                          subtitle: "OpenBurnBar provisions the recovery automation through Home Assistant's REST API. You'll never see config files.")
            }

            Spacer()
        }
    }
}

private struct FindInstanceStep: View {
    @Bindable var model: HomeAssistantRecoveryWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HeroBadge(icon: "network", tint: .whimsy)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Where is your Home Assistant?")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Type the URL Home Assistant lives at. The default is homeassistant.local:8123 — that works for almost every install on the same network.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FieldRow(
                title: "URL",
                placeholder: "homeassistant.local:8123",
                text: $model.inputURLString,
                icon: "globe"
            )
            .onSubmit { model.probeEnteredURL() }

            VStack(alignment: .leading, spacing: 6) {
                Text("Examples")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                ExampleRow(text: "homeassistant.local:8123")
                ExampleRow(text: "192.168.1.50:8123")
                ExampleRow(text: "https://my-ha.duckdns.org")
            }

            Spacer()

            HStack {
                Spacer()
                PrimaryButton(title: "Find Home Assistant", icon: "arrow.right.circle.fill") {
                    model.probeEnteredURL()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ProbingStep: View {
    let url: URL
    @State private var pulse = false
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(DesignSystem.Colors.whimsy.opacity(0.25), lineWidth: 3)
                    .frame(width: 96, height: 96)
                    .scaleEffect(pulse ? 1.4 : 0.9)
                    .opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.whimsy)
            }
            .onAppear { pulse = true }

            VStack(spacing: 6) {
                Text("Looking for Home Assistant…")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(url.host ?? url.absoluteString)
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
        }
    }
}

private struct ConnectTokenStep: View {
    @Bindable var model: HomeAssistantRecoveryWizardModel
    let url: URL
    let version: String?

    @State private var pasteFlash = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HeroBadge(icon: "key.viewfinder", tint: .ember)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Connect a long-lived access token")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Open your Home Assistant profile and create a long-lived token, then paste it here. The token never leaves this Mac — it's saved in the macOS keychain.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Button(action: { openTokenPage() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Open the token page in Home Assistant")
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.whimsy.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .strokeBorder(DesignSystem.Colors.whimsy.opacity(0.4), lineWidth: 0.5)
                    )
                    .foregroundStyle(DesignSystem.Colors.whimsy)
                }
                .buttonStyle(.plain)

                Text("Profile → Security → Long-Lived Access Tokens → Create Token")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.leading, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Token")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                HStack(spacing: 6) {
                    SecureField("Paste long-lived access token", text: $model.inputAccessToken)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.monoSmall)
                        .padding(DesignSystem.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .fill(DesignSystem.Colors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .strokeBorder(pasteFlash ? DesignSystem.Colors.success : DesignSystem.Colors.border, lineWidth: 0.7)
                        )
                        .onSubmit { model.validateToken() }

                    Button(action: pasteFromClipboard) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Paste from clipboard")
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                    )
                }

                Text("OpenBurnBar will only use this token to read your media players and write the recovery automation. You can revoke it anytime from Home Assistant.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let version {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("Reached \(url.host ?? url.absoluteString) — Home Assistant \(version)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("Reached \(url.host ?? url.absoluteString)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                PrimaryButton(title: "Connect", icon: "link") { model.validateToken() }
                    .disabled(model.inputAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func openTokenPage() {
        let tokenURL = url.appendingPathComponent("profile")
        NSWorkspace.shared.open(tokenURL)
    }

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        guard let str = pb.string(forType: .string), !str.isEmpty else { return }
        model.inputAccessToken = str.trimmingCharacters(in: .whitespacesAndNewlines)
        pasteFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            await MainActor.run { pasteFlash = false }
        }
    }
}

private struct PickDisplayStep: View {
    @Bindable var model: HomeAssistantRecoveryWizardModel
    let players: [HomeAssistantClient.MediaPlayer]
    let suggestedName: String

    private var sortedPlayers: [HomeAssistantClient.MediaPlayer] {
        let suggested = HomeAssistantClient.MediaPlayer.bestMatch(in: players, for: suggestedName)
        guard let suggested else { return players }
        return [suggested] + players.filter { $0.entityID != suggested.entityID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HeroBadge(icon: "tv.and.hifispeaker.fill", tint: .ember)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Pick the display Home Assistant should cast to")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Found \(players.count) media player\(players.count == 1 ? "" : "s") on your Home Assistant. Pick the same Nest Hub or Chromecast you usually mirror OpenBurnBar to.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sortedPlayers, id: \.entityID) { player in
                        PlayerRow(
                            player: player,
                            isSuggested: player.entityID == HomeAssistantClient.MediaPlayer.bestMatch(in: players, for: suggestedName)?.entityID,
                            onPick: { model.pickDisplay(player) }
                        )
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct PlayerRow: View {
    let player: HomeAssistantClient.MediaPlayer
    let isSuggested: Bool
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: iconName)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(player.supportsCast
                                     ? DesignSystem.Colors.ember
                                     : DesignSystem.Colors.textMuted)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(player.friendlyName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if isSuggested {
                            Text("Suggested")
                                .font(DesignSystem.Typography.tiny)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DesignSystem.Colors.success.opacity(0.18)))
                                .foregroundStyle(DesignSystem.Colors.success)
                        }
                        if !player.supportsCast {
                            Text("audio only")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.warning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DesignSystem.Colors.warning.opacity(0.15)))
                        }
                    }
                    Text(player.entityID + (player.model.map { " · \($0)" } ?? ""))
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(isSuggested
                                  ? DesignSystem.Colors.success.opacity(0.5)
                                  : DesignSystem.Colors.border, lineWidth: isSuggested ? 1 : 0.5)
            )
            .opacity(player.supportsCast ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        let lower = (player.friendlyName + " " + player.entityID + " " + (player.model ?? "")).lowercased()
        if lower.contains("nest hub max") { return "display" }
        if lower.contains("nest hub") || lower.contains("display") { return "display" }
        if lower.contains("chromecast") { return "tv" }
        if lower.contains("nest mini") || lower.contains("home mini") { return "homepod.mini.fill" }
        if lower.contains("nest audio") || lower.contains("home max") { return "homepod.fill" }
        return "tv.and.hifispeaker.fill"
    }
}

private struct ConfirmInstallStep: View {
    @Bindable var model: HomeAssistantRecoveryWizardModel
    let entityID: String
    let friendlyName: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HeroBadge(icon: "wand.and.stars", tint: .ember)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Install the recovery automation")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("OpenBurnBar will write a single Home Assistant automation called \"OpenBurnBar Smart Display Recovery.\" When native Cast can't reach your Hub, OpenBurnBar will fire it via webhook.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SummaryCard(rows: [
                ("Display", friendlyName),
                ("Entity", entityID),
                ("Mode", "REST API · automatic install"),
                ("Webhook ID", "Generated · stored on this Mac")
            ])

            VStack(alignment: .leading, spacing: 6) {
                BulletRow(icon: "checkmark.shield", title: "Local-only", subtitle: "The webhook trigger uses local_only: true so only devices on your network can call it.")
                BulletRow(icon: "arrow.triangle.2.circlepath", title: "Idempotent", subtitle: "Re-running the wizard updates the existing automation in place.")
                BulletRow(icon: "exclamationmark.shield", title: "No data leaves your network", subtitle: "OpenBurnBar only sends Home Assistant the dashboard URL and the Cast device name during recovery.")
            }

            Spacer()

            HStack {
                Button(action: { model.chooseBlueprintFallback() }) {
                    Label("Use blueprint instead", systemImage: "doc.append")
                        .font(DesignSystem.Typography.body)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Spacer()
                PrimaryButton(title: "Install", icon: "checkmark.circle.fill") {
                    model.installRecovery()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct LiveTestStep: View {
    @Bindable var model: HomeAssistantRecoveryWizardModel
    let config: HomeAssistantConfig

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HeroBadge(icon: "bolt.heart.fill", tint: .whimsy)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Test the recovery webhook")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("We'll call the same webhook OpenBurnBar uses when native Cast fails. Watch \(config.mediaPlayerFriendlyName.isEmpty ? "your display" : config.mediaPlayerFriendlyName) — it should briefly stop and reload the OpenBurnBar dashboard.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SummaryCard(rows: [
                ("Webhook", config.webhookURL?.absoluteString ?? "—"),
                ("Display", config.mediaPlayerFriendlyName.isEmpty ? config.mediaPlayerEntityID : config.mediaPlayerFriendlyName),
                ("Mode", config.setupMode == .rest ? "REST automation" : (config.setupMode == .blueprint ? "Blueprint" : "Manual webhook"))
            ])

            Spacer()

            HStack {
                Spacer()
                PrimaryButton(title: "Run test", icon: "play.circle.fill") { model.runLiveTest() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct DoneStep: View {
    let config: HomeAssistantConfig
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack {
                Spacer()
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.success.opacity(0.15))
                        .frame(width: 96, height: 96)
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.success)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Recovery is armed")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Whenever native Cast can't reach \(config.mediaPlayerFriendlyName.isEmpty ? "your Smart Display" : config.mediaPlayerFriendlyName), OpenBurnBar will hand the cast to Home Assistant. You don't need to do anything.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SummaryCard(rows: [
                ("Home Assistant", config.baseURL.host ?? config.baseURL.absoluteString),
                ("Display", config.mediaPlayerFriendlyName.isEmpty ? config.mediaPlayerEntityID : config.mediaPlayerFriendlyName),
                ("Setup", config.setupMode == .rest ? "REST automation" : (config.setupMode == .blueprint ? "Blueprint" : "Manual webhook")),
                ("Last verified", config.lastVerifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            ])

            Spacer()

            HStack {
                Spacer()
                PrimaryButton(title: "Done", icon: "checkmark") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct BlueprintStep: View {
    @Bindable var model: HomeAssistantRecoveryWizardModel
    let baseURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HeroBadge(icon: "doc.append", tint: .whimsy)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Install via blueprint")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Your Home Assistant doesn't expose the automation REST API, so we'll use a blueprint instead. One click opens Home Assistant with the blueprint pre-loaded — pick your display and you're done.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                BulletRow(icon: "1.circle.fill", title: "Open the blueprint in Home Assistant",
                          subtitle: "We'll open My Home Assistant which forwards to your local instance.")
                BulletRow(icon: "2.circle.fill", title: "Tap “Take Control” inside HA",
                          subtitle: "Home Assistant pre-fills the entire automation from the blueprint.")
                BulletRow(icon: "3.circle.fill", title: "Pick your display + paste the webhook ID",
                          subtitle: "OpenBurnBar already generated a unique webhook ID for you on this screen.")
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button(action: openImportLink) {
                    Label("Open in Home Assistant", systemImage: "arrow.up.right.square.fill")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
                }
                .buttonStyle(.plain)

                Button(action: copyWebhookID) {
                    Label("Copy webhook ID", systemImage: "doc.on.doc")
                        .font(DesignSystem.Typography.body)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            if let id = model.installedConfig?.webhookID {
                Text("Generated webhook ID: \(id)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                Spacer()
                PrimaryButton(title: "I've imported it — continue", icon: "arrow.right.circle.fill") {
                    _ = model.saveBlueprintWebhook()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func openImportLink() {
        if model.installedConfig?.webhookID == nil {
            _ = model.saveBlueprintWebhook()
        }
        NSWorkspace.shared.open(HomeAssistantBlueprintInstaller.importDeepLink())
    }

    private func copyWebhookID() {
        let id = model.installedConfig?.webhookID ?? HomeAssistantWebhookID.generate()
        if model.installedConfig == nil { _ = model.saveBlueprintWebhook(generatedID: id) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(id, forType: .string)
    }
}

private struct FailedStep: View {
    let message: String
    let recoverable: Bool
    let previous: HomeAssistantRecoveryWizardModel.Step.PreviousStep
    let onRetry: () -> Void
    let onClose: () -> Void
    let onSwitchToBlueprint: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HeroBadge(icon: "exclamationmark.triangle.fill", tint: .warning)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("That didn't work")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(message)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Things to try")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                ExampleRow(text: hint1)
                ExampleRow(text: hint2)
            }

            Spacer()

            HStack {
                Button(action: onClose) {
                    Text("Close")
                        .font(DesignSystem.Typography.body)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Spacer()

                if previous == .installRecovery {
                    Button(action: onSwitchToBlueprint) {
                        Label("Try blueprint", systemImage: "doc.append")
                            .font(DesignSystem.Typography.body)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                            .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }

                if recoverable {
                    PrimaryButton(title: "Try again", icon: "arrow.clockwise") { onRetry() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var hint1: String {
        switch previous {
        case .findInstance: return "Confirm your Mac and Home Assistant are on the same WiFi."
        case .connectToken: return "Tokens are case-sensitive — copy the full string from HA."
        case .pickDisplay: return "Add the Cast device to Home Assistant first (Settings → Devices → Add Integration → Google Cast)."
        case .installRecovery: return "Older HA versions don't expose the automation REST API. Try the blueprint instead."
        case .liveTest: return "Make sure the Hub is on and showing the home screen."
        case .blueprint: return "Try opening the blueprint manually from Home Assistant → Blueprints."
        }
    }

    private var hint2: String {
        switch previous {
        case .findInstance: return "Try a numeric IP if .local doesn't resolve (System Settings → Network → Wi-Fi → Details)."
        case .connectToken: return "If the token was issued for the wrong account, recreate it under your admin profile."
        case .pickDisplay: return "Some entity types appear after the device shows up in HA's history — wait a few seconds and retry."
        case .installRecovery: return "Confirm the token has admin scope; non-admin tokens can't write automations."
        case .liveTest: return "Disable any HA proxy in front of /api/webhook/* so the local request reaches HA directly."
        case .blueprint: return "After importing, save the automation and tap Test from inside Home Assistant."
        }
    }
}

private struct BusyStep: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .progressViewStyle(.circular)
                .tint(DesignSystem.Colors.whimsy)
            VStack(spacing: 6) {
                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(message)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Reusable building blocks

private enum HeroBadgeTint {
    case ember
    case whimsy
    case warning
}

private struct HeroBadge: View {
    let icon: String
    let tint: HeroBadgeTint

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(gradient)
                .frame(width: 64, height: 64)
                .shadow(color: shadowColor, radius: 14, y: 5)
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var gradient: LinearGradient {
        switch tint {
        case .ember:
            return LinearGradient(colors: [DesignSystem.Colors.ember, DesignSystem.Colors.coral],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .whimsy:
            return LinearGradient(colors: [DesignSystem.Colors.whimsy, DesignSystem.Colors.purple],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .warning:
            return LinearGradient(colors: [DesignSystem.Colors.warning, DesignSystem.Colors.gold],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var shadowColor: Color {
        switch tint {
        case .ember:   return DesignSystem.Colors.ember.opacity(0.35)
        case .whimsy:  return DesignSystem.Colors.whimsy.opacity(0.35)
        case .warning: return DesignSystem.Colors.warning.opacity(0.35)
        }
    }
}

private struct BulletRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.ember)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(DesignSystem.Colors.ember.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.monoSmall)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.7)
                )
                .autocorrectionDisabled(true)
        }
    }
}

private struct ExampleRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(text)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .textSelection(.enabled)
        }
    }
}

private struct SummaryCard: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, pair in
                HStack(alignment: .top) {
                    Text(pair.0)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 96, alignment: .leading)
                    Text(pair.1)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                if idx < rows.count - 1 {
                    Divider().background(DesignSystem.Colors.borderSubtle)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }
}

private struct PrimaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stable identity for transitions

private func stepKey(_ step: HomeAssistantRecoveryWizardModel.Step) -> String {
    switch step {
    case .why: return "why"
    case .findInstance: return "find"
    case .probing: return "probing"
    case .connectToken: return "connectToken"
    case .validatingToken: return "validatingToken"
    case .pickDisplay: return "pickDisplay"
    case .loadingDisplays: return "loadingDisplays"
    case .installRecovery: return "installRecovery"
    case .installing: return "installing"
    case .liveTest: return "liveTest"
    case .testing: return "testing"
    case .done: return "done"
    case .blueprintIntro: return "blueprint"
    case .failed: return "failed"
    }
}
