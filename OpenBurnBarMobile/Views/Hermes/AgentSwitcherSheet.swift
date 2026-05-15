import SwiftUI
import OpenBurnBarCore

// MARK: - Agent Switcher
//
// ChatGPT-app-style picker for the Assistants tab. Replaces the old
// text-glyph runtime pill. Surfaces three things in one tap target:
//
//   1. Swap between agent providers (Hermes / Pi / Codex / Claude / OpenClaw)
//      using brand icons rather than names.
//   2. See the current connection status for each provider at a glance
//      (online / pending / offline / bridged) via a corner status dot.
//   3. For Hermes — which is an *agent harness*, not a model — swap the
//      underlying model it runs on. Other providers don't expose a model
//      knob today, so that section is hidden.
//
// Components in this file:
//   • `AgentIdentityChip` — toolbar `.principal` pill (icon + name + sub-model + chevron).
//   • `ConnectionStatusButton` — toolbar `.topBarLeading` status indicator.
//   • `AgentSwitcherSheet` — the picker sheet itself.
//   • `AgentTile` — runtime tile rendered inside the sheet.

// MARK: - Runtime → Brand mapping

extension AssistantRuntimeID {
    /// Brand identity used to render the provider icon. Hermes maps to the
    /// Hermes glyph (the harness itself) rather than to whichever underlying
    /// model is currently selected — that one is rendered as a secondary
    /// sub-icon next to the chip.
    var agentProvider: AgentProvider {
        switch self {
        case .hermes:   return .hermes
        case .pi:       return .piAgent
        case .codex:    return .codex
        case .claude:   return .claudeCode
        case .openClaw: return .openClaw
        }
    }

    /// Solid brand tint used for the active-tile ring and labels in the
    /// switcher sheet. Mirrors the gradient endpoints used elsewhere.
    var brandTint: Color {
        switch self {
        case .hermes:   return MobileTheme.hermesAureate
        case .pi:       return MobileTheme.whimsy
        case .codex:    return Color(hex: "2ECC71")
        case .claude:   return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        }
    }

    /// Short one-word descriptor of what this runtime is, surfaced under the
    /// tile name so a new user understands "Hermes" is a harness, not a model.
    var kindLabel: String {
        switch self {
        case .hermes:   return "Agent harness"
        case .pi:       return "Empathy agent"
        case .codex:    return "CLI agent"
        case .claude:   return "CLI agent"
        case .openClaw: return "Local agent"
        }
    }
}

// MARK: - Runtime Status

enum RuntimeStatus: Equatable {
    case online
    case pending
    case degraded
    case offline
    case unauthorized
    case bridged
    case unknown

    var color: Color {
        switch self {
        case .online:        return MobileTheme.Colors.success
        case .bridged:       return MobileTheme.Colors.success.opacity(0.7)
        case .pending:       return MobileTheme.amber
        case .degraded:      return MobileTheme.warning
        case .unauthorized:  return MobileTheme.warning
        case .offline:       return MobileTheme.Colors.textMuted
        case .unknown:       return MobileTheme.Colors.textMuted
        }
    }

    var label: String {
        switch self {
        case .online:        return "Online"
        case .bridged:       return "Bridged via Mac"
        case .pending:       return "Pending"
        case .degraded:      return "Degraded"
        case .unauthorized:  return "Sign-in needed"
        case .offline:       return "Offline"
        case .unknown:       return "Unknown"
        }
    }

    init(_ status: HermesConnectionStatus) {
        switch status {
        case .online:        self = .online
        case .pending:       self = .pending
        case .degraded:      self = .degraded
        case .offline:       self = .offline
        case .unauthorized:  self = .unauthorized
        case .revoked:       self = .unauthorized
        }
    }

    init(_ status: PiConnectionStatus) {
        switch status {
        case .online:        self = .online
        case .pending:       self = .pending
        case .degraded:      self = .degraded
        case .offline:       self = .offline
        case .unauthorized:  self = .unauthorized
        case .revoked:       self = .unauthorized
        }
    }
}

// MARK: - Status resolver

@MainActor
struct AssistantStatusResolver {
    let hermesService: HermesService
    let piService: PiService

    func status(for runtime: AssistantRuntimeID) -> RuntimeStatus {
        switch runtime {
        case .hermes:
            return RuntimeStatus(hermesService.selectedConnection.status)
        case .pi:
            return RuntimeStatus(piService.selectedConnection.status)
        case .codex, .claude, .openClaw:
            // CLI-style runtimes bridge through the Mac. We use the Hermes
            // relay reachability as a proxy — if Hermes can talk to the Mac,
            // these can too.
            return hermesService.isReachable ? .bridged : .offline
        }
    }

    /// Short host/endpoint label used as the trailing crumb on the
    /// connection-status button. Falls back to the connection display name.
    func endpointLabel(for runtime: AssistantRuntimeID) -> String {
        switch runtime {
        case .hermes:
            return hermesService.selectedConnection.endpointURL.flatMap(host(from:))
                ?? hermesService.selectedConnection.displayName
        case .pi:
            return piService.selectedConnection.endpointURL.flatMap(host(from:))
                ?? piService.selectedConnection.displayName
        case .codex, .claude, .openClaw:
            return hermesService.selectedConnection.endpointURL.flatMap(host(from:))
                ?? hermesService.selectedConnection.displayName
        }
    }

    private func host(from urlString: String) -> String? {
        guard !urlString.isEmpty,
              let url = URL(string: urlString),
              let host = url.host
        else { return nil }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

// MARK: - Hermes model summary

@MainActor
struct HermesModelSummary {
    let displayName: String
    let provider: AgentProvider

    init(service: HermesService) {
        let option = service.selectedModelOption
        let raw = service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "hermes"
        self.provider = option?.agentProvider ?? hermesAgentProvider(for: raw)
        self.displayName = option?.displayName
            ?? service.selectedModelID
            ?? service.selectedConnection.advertisedModel
            ?? "Automatic"
    }
}

// MARK: - Agent Identity Chip (toolbar principal)

struct AgentIdentityChip: View {
    let runtime: AssistantRuntimeID
    let runtimeStatus: RuntimeStatus
    /// Only set for Hermes — the underlying model the harness is routed to.
    let modelSummary: HermesModelSummary?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    UnifiedProviderLogoView(provider: runtime.agentProvider, size: 26)
                    Circle()
                        .fill(runtimeStatus.color)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .stroke(MobileTheme.Colors.background, lineWidth: 1.5)
                        )
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(runtime.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)

                    if let modelSummary {
                        HStack(spacing: 3) {
                            UnifiedProviderLogoView(
                                provider: modelSummary.provider,
                                size: 10,
                                useFallbackColor: true
                            )
                            Text(modelSummary.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(runtime.kindLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.7))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(runtime.brandTint.opacity(0.35), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Switch agent. Current: \(runtime.displayName), \(runtimeStatus.label)" + (modelSummary.map { ", routed to \($0.displayName)" } ?? ""))
        .accessibilityHint("Opens the agent and model switcher")
    }
}

// MARK: - Connection Status Button (toolbar leading)

struct ConnectionStatusButton: View {
    let status: RuntimeStatus
    let endpointLabel: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status.color)
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.6))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection: \(status.label). \(endpointLabel)")
        .accessibilityHint("Opens connection settings")
    }

    private var iconName: String {
        switch status {
        case .online, .bridged:
            return "antenna.radiowaves.left.and.right"
        case .pending, .degraded:
            return "antenna.radiowaves.left.and.right.slash"
        case .offline, .unknown:
            return "wifi.slash"
        case .unauthorized:
            return "lock.shield"
        }
    }
}

// MARK: - Agent Switcher Sheet

struct AgentSwitcherSheet: View {
    let visibleRuntimes: [AssistantRuntimeID]
    @Binding var runtime: AssistantRuntimeID
    @Bindable var hermesService: HermesService
    @Bindable var piService: PiService
    let onManageConnections: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showHermesModelPicker = false

    private var resolver: AssistantStatusResolver {
        AssistantStatusResolver(hermesService: hermesService, piService: piService)
    }

    private var hermesSummary: HermesModelSummary {
        HermesModelSummary(service: hermesService)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)

                ScrollView {
                    VStack(spacing: MobileTheme.Spacing.lg) {
                        agentSection
                        if runtime == .hermes {
                            hermesModelSection
                        } else {
                            nonHermesModelHint
                        }
                        connectionFooter
                    }
                    .padding(MobileTheme.Spacing.lg)
                }
            }
            .navigationTitle("Switch Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showHermesModelPicker) {
            HermesModelPickerSheet(service: hermesService)
        }
    }

    // MARK: Agent section

    private var agentSection: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                sectionHeader("Agent", systemName: "person.2.crop.square.stack")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(visibleRuntimes, id: \.self) { r in
                            AgentTile(
                                runtime: r,
                                isActive: r == runtime,
                                status: resolver.status(for: r),
                                onTap: {
                                    if r != runtime {
                                        runtime = r
                                        HapticBus.tabChange()
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Hermes model section

    private var hermesModelSection: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                sectionHeader("Powered by", systemName: "cpu")

                Button {
                    showHermesModelPicker = true
                } label: {
                    HStack(spacing: MobileTheme.Spacing.md) {
                        UnifiedProviderLogoView(
                            provider: hermesSummary.provider,
                            size: 38,
                            useFallbackColor: true
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(hermesSummary.displayName)
                                .font(MobileTheme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Text("Hermes is an agent harness — tap to change the underlying model")
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    .padding(MobileTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Hermes model picker")
            }
        }
    }

    private var nonHermesModelHint: some View {
        AuroraGlassCard(variant: .compact, cornerRadius: MobileTheme.Radius.md) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                UnifiedProviderLogoView(provider: runtime.agentProvider, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(runtime.displayName) runs on its own model")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Model selection for \(runtime.displayName) is managed by the runtime itself. Use Manage connections to point it at a different host.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Connection footer

    private var connectionFooter: some View {
        Button {
            onManageConnections()
            dismiss()
        } label: {
            HStack(spacing: MobileTheme.Spacing.md) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(runtime.brandTint)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(runtime.brandTint.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage connections")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(resolver.endpointLabel(for: runtime))
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            .padding(MobileTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.45), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String, systemName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.hermesAureate)
            Text(title)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
        }
    }
}

// MARK: - Agent Tile

struct AgentTile: View {
    let runtime: AssistantRuntimeID
    let isActive: Bool
    let status: RuntimeStatus
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    UnifiedProviderLogoView(
                        provider: runtime.agentProvider,
                        size: 44,
                        useFallbackColor: true
                    )
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isActive
                                  ? runtime.brandTint.opacity(0.18)
                                  : MobileTheme.Colors.surfaceElevated.opacity(0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(isActive
                                            ? runtime.brandTint.opacity(0.75)
                                            : MobileTheme.Colors.border.opacity(0.4),
                                            lineWidth: isActive ? 1.5 : 0.5)
                            )
                            .shadow(
                                color: isActive ? runtime.brandTint.opacity(0.35) : .clear,
                                radius: isActive ? 10 : 0,
                                y: isActive ? 3 : 0
                            )
                    )

                    Circle()
                        .fill(status.color)
                        .frame(width: 11, height: 11)
                        .overlay(
                            Circle()
                                .stroke(MobileTheme.Colors.background, lineWidth: 1.5)
                        )
                        .offset(x: 3, y: -3)
                }
                .frame(width: 64, height: 64)

                VStack(spacing: 1) {
                    Text(runtime.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(isActive ? runtime.brandTint : MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(status.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(runtime.displayName), \(runtime.kindLabel), \(status.label)" + (isActive ? ", selected" : ""))
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }
}
