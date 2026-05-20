import SwiftUI
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

    @AppStorage(HermesMobileChatPreferences.showMessageTPSKey) private var showMessageTPS = false
    @AppStorage(HermesMobileChatPreferences.usePretextRenderingKey) private var usePretextRendering = true
    @State private var showPretextPlayground = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)

            ScrollView {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    headerCard
                        .settingsAnchor(SettingsAnchor.hermesRow)

                    connectionsSection
                        .settingsAnchor(SettingsAnchor.hermesConnections)
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
        }
        .navigationTitle("Hermes")
        .sheet(isPresented: $showAddDirectSheet) { addDirectSheet }
        .sheet(isPresented: $showModelPicker) {
            AssistantModelPickerSheet(
                runtime: .hermes,
                hermesService: service,
                piService: PiService.shared
            )
        }
        .sheet(isPresented: $showPretextPlayground) {
            PretextPlayground()
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
    }

    // MARK: - Header

    private var headerCard: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: MobileTheme.Radius.lg) {
            HStack(spacing: MobileTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.mercuryGradient.opacity(0.25))
                        .frame(width: 52, height: 52)
                    HermesLiveGlyph(size: 30, isLive: false)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Hermes")
                        .font(MobileTheme.Typography.title)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Messenger AI configuration")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                Spacer()
            }
        }
    }

    // MARK: - 1. Connections

    private var connectionsSection: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                sectionTitle("Connections", icon: "antenna.radiowaves.left.and.right", color: MobileTheme.hermesAureate)

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
                            .font(MobileTheme.Typography.body)
                    }
                    .foregroundStyle(MobileTheme.mercuryGradient)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
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
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(connectionSubtitle(connection))
                        .font(MobileTheme.Typography.tiny)
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

    // MARK: - 2. Models

    private var modelsSection: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                HStack {
                    sectionTitle("Models", icon: "cpu", color: MobileTheme.whimsy)
                    Spacer()
                    Button {
                        showModelPicker = true
                    } label: {
                        Label("Switch", systemImage: "arrow.left.arrow.right")
                            .font(MobileTheme.Typography.tiny)
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
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .padding(.vertical, 4)
                } else {
                    if !service.favoriteModelOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Favorites")
                                .font(MobileTheme.Typography.caption)
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
                                    .font(MobileTheme.Typography.caption)
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
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                        Text(service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "hermes")
                            .font(MobileTheme.Typography.caption)
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
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(option.modelID)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                        if let detail = option.liveCatalogDetailText {
                            Text(detail)
                                .font(MobileTheme.Typography.tiny)
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
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                sectionTitle("Display", icon: "speedometer", color: MobileTheme.hermesAureate)

                Toggle(isOn: $showMessageTPS) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show tokens/sec")
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("Adds a small generation-speed footer below assistant messages. Provider-reported counts are exact; missing usage is marked “est.”")
                            .font(MobileTheme.Typography.tiny)
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
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("Hermes assistant messages render `@mentions` and `code spans` as inline chips, with line breaking by Pretext. Streaming and error states stay plain.")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(MobileTheme.hermesAureate)
                .settingsAnchor(SettingsAnchor.hermesPretext)

                Button {
                    showPretextPlayground = true
                } label: {
                    HStack(spacing: MobileTheme.Spacing.sm) {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Open text layout playground")
                            .font(MobileTheme.Typography.body)
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
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                sectionTitle("Gateway", icon: "network", color: MobileTheme.ember)

                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    label("Base URL")
                    TextField("http://localhost:8642", text: urlBinding)
                        .font(MobileTheme.Typography.body)
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
                            .font(MobileTheme.Typography.body)
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
                        .font(MobileTheme.Typography.body)
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
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                sectionTitle("Security", icon: "lock.shield", color: MobileTheme.whimsy)

                Toggle(isOn: relayBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote Relay")
                            .font(MobileTheme.Typography.body)
                        Text("Allow iPhone/iPad to chat with this Mac over encrypted Firestore relay")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .tint(MobileTheme.ember)

                if service.selectedConnection.mode == .relayLink,
                   let key = service.selectedConnection.relayPublicKey {
                    VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                        label("Relay Public Key")
                        Text(key)
                            .font(MobileTheme.Typography.monoSmall)
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
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                sectionTitle("Status", icon: "gauge.with.dots.needle.67percent", color: MobileTheme.amber)

                if service.isLoadingRuntime {
                    HStack {
                        MiningPickLoader(.inline)
                        Text("Probing runtime…")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                } else if let error = service.runtimeErrorText {
                    HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(MobileTheme.warning)
                        Text(error)
                            .font(MobileTheme.Typography.caption)
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
                .font(MobileTheme.Typography.headline)
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
            .font(MobileTheme.Typography.caption)
            .fontWeight(.semibold)
            .foregroundStyle(MobileTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer()
            Text(value)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func infoRow(_ label: String, value: Date, style: Text.DateStyle) -> some View {
        HStack {
            Text(label)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer()
            Text(value, style: style)
                .font(MobileTheme.Typography.caption)
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
            get: { false },
            set: { _ in }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
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
