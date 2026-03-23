import SwiftUI

struct CursorConnectorView: View {
    @State private var manager = CursorConnectorManager.shared
    @State private var legacyConnectorExpanded = false
    let dataStore: DataStore

    private var zaiBinding: Binding<ConnectorProviderConfig> {
        binding(for: .zai)
    }

    private var minimaxBinding: Binding<ConnectorProviderConfig> {
        binding(for: .minimax)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            hero
            providerCluster
            DisclosureGroup(isExpanded: $legacyConnectorExpanded) {
                tunnelCluster
                routeDiagnostics
            } label: {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Legacy: Cursor built-in OpenAI override")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(legacyConnectorSummary)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignSystem.Spacing.lg)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.5)
            )
        }
        .onAppear {
            manager.attach(dataStore: dataStore)
            if manager.config.isEnabled {
                legacyConnectorExpanded = true
            }
        }
        .onChange(of: manager.config.isEnabled) { _, enabled in
            if enabled {
                legacyConnectorExpanded = true
            }
        }
    }

    private var legacyConnectorSummary: String {
        if manager.config.isEnabled {
            return "Active — BurnBar is patching Cursor’s OpenAI base URL. Prefer the daemon + extension for new setups."
        }
        if !manager.health.cloudflaredInstalled {
            return "Optional. Only if you want Cursor’s own model picker to hit Z.ai / MiniMax through BurnBar; requires cloudflared for a public HTTPS URL."
        }
        return "Optional. Writes Cursor’s BYOK settings and uses a quick tunnel so Cursor can reach the local router."
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.ember.opacity(0.16),
                            DesignSystem.Colors.whimsy.opacity(0.14),
                            DesignSystem.Colors.background
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Cursor & providers")
                            .font(DesignSystem.Typography.display)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Use the BurnBar Daemon above plus the BurnBar editor extension for routed runs—no tunnel. The section below is a legacy path that patches Cursor’s SQLite OpenAI override when you want those models inside Cursor’s built-in chat.")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    statusBadge(text: manager.config.statusMessage, success: manager.config.isEnabled)
                }

                routeStrip

                HStack(spacing: DesignSystem.Spacing.md) {
                    GlassButton(
                        title: manager.config.isEnabled ? "Reconnect" : "Connect",
                        icon: manager.config.isEnabled ? "arrow.triangle.2.circlepath" : "cursorarrow.click.2",
                        style: .prominent
                    ) {
                        Task { await manager.connect() }
                    }
                    GlassButton(title: "Disconnect", icon: "power", style: .regular) {
                        Task { await manager.disconnect() }
                    }
                    .opacity(manager.config.isEnabled ? 1 : 0.55)
                    .disabled(!manager.config.isEnabled)
                    GlassButton(title: "Import Factory", icon: "tray.and.arrow.down", style: .regular) {
                        manager.importFromFactorySettings()
                    }
                }

                if let error = manager.lastError, !error.isEmpty {
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.warning)
                }
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .frame(minHeight: 240)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.7)
        )
    }

    private var routeStrip: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            routeNode(label: "Choose models", state: !manager.config.exposedModels.isEmpty)
            routeLink
            routeNode(label: "Public URL", state: manager.config.tunnel.publicBaseURL != nil)
            routeLink
            routeNode(label: "Apply Cursor", state: manager.config.lastAppliedAt != nil)
            routeLink
            routeNode(label: "Verify", state: manager.health.publicBaseURLReachable)
        }
    }

    private var routeLink: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.85))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private func routeNode(label: String, state: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Circle()
                .fill(state ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted.opacity(0.35))
                .frame(width: 9, height: 9)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private var providerCluster: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
            providerPanel(provider: .zai, config: zaiBinding, accent: DesignSystem.Colors.accent(for: .zai))
            providerPanel(provider: .minimax, config: minimaxBinding, accent: DesignSystem.Colors.accent(for: .minimax))
        }
    }

    private func providerPanel(provider: ConnectorProvider, config: Binding<ConnectorProviderConfig>, accent: Color) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text(provider.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Keys stay in local Keychain. Pick only the model IDs you want Cursor to see.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { config.wrappedValue.enabled },
                        set: { newValue in
                            manager.updateProviderConfig(provider) { $0.enabled = newValue }
                        }
                    ))
                    .toggleStyle(.switch)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    label("API key")
                    SecureField("Paste \(provider.displayName) key", text: Binding(
                        get: { manager.apiKey(for: provider) },
                        set: { manager.setAPIKey($0, for: provider) }
                    ))
                    .textFieldStyle(.plain)
                    .padding(DesignSystem.Spacing.md)
                    .background(DesignSystem.Colors.background)
                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(accent.opacity(0.35), lineWidth: 0.7)
                    )
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    label("Base URL")
                    TextField("", text: Binding(
                        get: { config.wrappedValue.baseURL },
                        set: { newValue in manager.updateProviderConfig(provider) { $0.baseURL = newValue } }
                    ))
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.monoSmall)
                    .padding(DesignSystem.Spacing.md)
                    .background(DesignSystem.Colors.background)
                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.8), lineWidth: 0.7)
                    )
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    label("Expose these models")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(config.wrappedValue.id.suggestedModels, id: \.self) { model in
                            modelPill(
                                label: model,
                                selected: config.wrappedValue.selectedModels.contains(model)
                            ) {
                                manager.updateProviderConfig(provider) { current in
                                    if current.selectedModels.contains(model) {
                                        current.selectedModels.removeAll { $0 == model }
                                    } else {
                                        current.selectedModels.append(model)
                                    }
                                }
                            }
                        }
                    }

                    TextField("Custom model IDs, comma separated", text: Binding(
                        get: { config.wrappedValue.customModels.joined(separator: ", ") },
                        set: { newValue in
                            let models = newValue
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                                .filter(CursorConnectorManager.supportedModel)
                            manager.updateProviderConfig(provider) { $0.customModels = models }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.monoSmall)
                    .padding(DesignSystem.Spacing.md)
                    .background(DesignSystem.Colors.background)
                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.8), lineWidth: 0.7)
                    )
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
    }

    private var tunnelCluster: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Public HTTPS URL (cloudflared)")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Cursor rejects localhost for this override, so this legacy path runs cloudflared’s ephemeral quick tunnel to expose the local router.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Spacer()
                    statusBadge(text: manager.health.cloudflaredInstalled ? "cloudflared ready" : "cloudflared missing", success: manager.health.cloudflaredInstalled)
                }

                HStack(spacing: DesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        label("What you need")
                        Text("1. Install `cloudflared` once.\n2. Press Connect.\n3. Keep BurnBar running while Cursor uses these models.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        label("Public base URL")
                        Text(manager.config.tunnel.publicBaseURL ?? "Not connected yet")
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(manager.config.tunnel.publicBaseURL == nil ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textPrimary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: DesignSystem.Spacing.sm) {
                        if manager.health.homebrewInstalled && !manager.health.cloudflaredInstalled {
                            GlassButton(title: "Install cloudflared", icon: "shippingbox", style: .regular) {
                                Task { await manager.installCloudflaredWithHomebrew() }
                            }
                        } else if !manager.health.cloudflaredInstalled {
                            GlassButton(title: "Open install guide", icon: "book", style: .regular) {
                                manager.openCloudflareDocs()
                            }
                        }
                        GlassButton(title: "Cursor docs", icon: "link", style: .regular) {
                            manager.openCursorDocs()
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var routeDiagnostics: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Recent route activity")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                if manager.recentRouteLog.isEmpty {
                    Text("No routed requests yet.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        ForEach(Array(manager.recentRouteLog.suffix(6).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !manager.recentUsageEvents.isEmpty {
                    Divider().background(DesignSystem.Colors.border)
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Latest usage")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        ForEach(manager.recentUsageEvents.prefix(4)) { event in
                            HStack {
                                Text("\(event.provider.displayName) · \(event.model)")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Text(event.cost.formatAsCost())
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                    }
                }

                Text("Unsupported in v1: Kimi and Pony research-preview models are intentionally excluded from import and exposure.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
    }

    private func statusBadge(text: String, success: Bool) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(success ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.85))
            .clipShape(.capsule)
    }

    private func modelPill(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(selected ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.background)
                .clipShape(.capsule)
                .overlay(
                    Capsule()
                        .stroke(selected ? DesignSystem.Colors.whimsy.opacity(0.55) : DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.7)
                )
        }
        .buttonStyle(.plain)
    }

    private func binding(for provider: ConnectorProvider) -> Binding<ConnectorProviderConfig> {
        Binding(
            get: { manager.providerConfig(for: provider) },
            set: { newValue in manager.updateProviderConfig(provider) { $0 = newValue } }
        )
    }
}
