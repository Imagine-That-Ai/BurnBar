import SwiftUI
import OpenBurnBarCore

// MARK: - Pi Settings View
//
// Sibling of `HermesSettingsView`. Renders Pi-specific status, hosts, models,
// and the relay/security card. Composed from the same `AuroraGlassCard`
// primitives so visuals stay aligned with the Hermes settings surface.

struct PiSettingsView: View {
    @Bindable var service: PiService
    let authStore: AuthStore

    @State private var showConnectionSheet = false

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    headerCard
                        .settingsAnchor(SettingsAnchor.piRow)
                    statusCard
                    hostsCard
                        .settingsAnchor(SettingsAnchor.piHosts)
                    modelsCard
                        .settingsAnchor(SettingsAnchor.piModels)
                    Spacer(minLength: MobileTheme.Spacing.xxxl)
                }
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.top, MobileTheme.Spacing.lg)
            }
        }
        .navigationTitle("Pi")
        .sheet(isPresented: $showConnectionSheet) {
            AssistantConnectionSheet(
                hermesService: nil,
                piService: service,
                focusedRuntime: .pi
            )
        }
        .task { await service.refreshRuntime() }
    }

    // MARK: - Header

    private var headerCard: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: MobileTheme.Radius.lg) {
            HStack(spacing: MobileTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.piGradient.opacity(0.25))
                        .frame(width: 52, height: 52)
                    Text(AssistantRuntimeID.pi.glyph)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(MobileTheme.whimsy)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pi")
                        .font(MobileTheme.Typography.title)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("AI Environment configuration")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                sectionTitle("Status", icon: "gauge.with.dots.needle.67percent")

                if service.isLoadingRuntime {
                    HStack(spacing: MobileTheme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Probing Pi gateway…")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                } else if service.isReachable {
                    Label("Online", systemImage: "checkmark.seal.fill")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.success)
                } else if let err = service.runtimeErrorText {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Pi gateway not reached yet.", systemImage: "questionmark.circle")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                Button {
                    Task { await service.refreshRuntime() }
                } label: {
                    Label("Re-check connection", systemImage: "arrow.clockwise")
                        .font(MobileTheme.Typography.body)
                }
                .buttonStyle(.borderedProminent)
                .tint(MobileTheme.whimsy)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Hosts

    private var hostsCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack {
                    sectionTitle("Hosts", icon: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Button("Change Host") { showConnectionSheet = true }
                        .buttonStyle(.plain)
                        .font(MobileTheme.Typography.caption.bold())
                        .foregroundStyle(MobileTheme.whimsy)
                }

                ForEach(service.connections) { connection in
                    HStack(spacing: MobileTheme.Spacing.md) {
                        Circle()
                            .fill(statusColor(connection.status))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.displayName)
                                .font(MobileTheme.Typography.body)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                            Text(subtitleFor(connection))
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                        Spacer()
                        if service.selectedConnection.id == connection.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(MobileTheme.piGradient)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { _ = service.selectConnection(connection) }
                }
            }
        }
    }

    // MARK: - Models

    private var modelsCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                sectionTitle("Models", icon: "cpu")
                if service.modelOptions.isEmpty {
                    Text("No models discovered yet.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } else {
                    ForEach(service.modelOptions) { option in
                        Button {
                            service.selectModel(option)
                        } label: {
                            HStack(spacing: MobileTheme.Spacing.sm) {
                                Text(option.displayName)
                                    .font(MobileTheme.Typography.body)
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                Spacer()
                                if service.selectedModelID == option.modelID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(MobileTheme.whimsy)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        } icon: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(MobileTheme.whimsy.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.whimsy)
            }
        }
    }

    private func statusColor(_ status: PiConnectionStatus) -> Color {
        switch status {
        case .online: return MobileTheme.Colors.success
        case .pending, .degraded: return MobileTheme.Colors.warning
        case .offline: return MobileTheme.Colors.textMuted
        case .unauthorized, .revoked: return MobileTheme.Colors.error
        }
    }

    private func subtitleFor(_ connection: PiConnectionRecord) -> String {
        var parts: [String] = []
        switch connection.mode {
        case .local: parts.append("Local")
        case .directURL: parts.append("Direct")
        case .relayLink: parts.append("Relay")
        }
        if let url = connection.endpointURL { parts.append(url) }
        parts.append(connection.status.rawValue.capitalized)
        return parts.joined(separator: " · ")
    }
}
