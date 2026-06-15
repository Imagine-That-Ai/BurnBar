import OSLog
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

let hermesSettingsLogger = Logger(subsystem: "com.openburnbar.mobile", category: "HermesSettings")

//
// Comprehensive Hermes configuration surface. Four glass-card sections:
//   1. Connections — list, select, disconnect, add direct-URL entry
//   2. Gateway — base URL, bearer token, model override
//   3. Security — relay encryption details, pairing status
//   4. Status — runtime health, capabilities, model info, last-seen
struct HermesSettingsView: View {
    let service: HermesService

    let authStore: AuthStore

    @State var showAddDirectSheet = false

    @State var showTokenEditor = false

    @State var editingToken = ""

    @State var newDirectURL = ""

    @State var newDirectName = ""

    @State var showDeleteConfirm: HermesConnectionRecord?

    @State var showModelDetail: HermesRuntimeModelOption?

    @State var showModelPicker = false

    @State var gatewayStore = HermesGatewaySettingsStore()

    @State var gatewayPairingCode = ""

    @State var gatewayTestMessage = "Hello Hermes from OpenBurnBar iPhone."

    @State var showGatewaySignIn = false

    @State var gatewaySuccessClient: HermesGatewayClientRecord?

    @State var gatewayPrivacyClient: HermesGatewayClientRecord?

    @State var copiedGatewayCommand: HermesGatewayWizardCommand?

    @State var showGatewayAdditionalPairing = false

    @State var showPruneGatewayClientsConfirm = false

    @AppStorage(HermesMobileChatPreferences.showMessageTPSKey) var showMessageTPS = false

    @AppStorage(HermesMobileChatPreferences.usePretextRenderingKey) var usePretextRendering = true

    @State var showPretextPlayground = false

    @Environment(\.cloudSubscriptionStore) var cloudSubscriptionStore

    @Environment(\.dismiss) var dismiss

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
        .sheet(item: $gatewayPrivacyClient) { client in
            let state = gatewayPrivacyState(for: client)
            HermesGatewayPrivacySheet(
                state: state,
                clientDisplayName: client.displayName,
                safetyCode: gatewayStore.agentSafetyCode(for: client),
                onReconnect: state == .reconnectNeeded
                    ? { gatewayStore.repinAgentKeyAfterUserConfirmation(for: client) }
                    : nil
            )
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
        .alert("Remove older Hermes entries?", isPresented: $showPruneGatewayClientsConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove older entries", role: .destructive) {
                Task { await gatewayStore.pruneStaleClients() }
            }
        } message: {
            Text("This revokes older gateway entries that appear to belong to the same device and keeps the newest active entry visible.")
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

    var headerCard: some View {
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

    var connectionsSection: some View {
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

    func connectionRow(_ connection: HermesConnectionRecord) -> some View {
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

    func connectionSubtitle(_ c: HermesConnectionRecord) -> String {
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

    func connectionStatusColor(_ status: HermesConnectionStatus) -> Color {
        switch status {
        case .online:     return MobileTheme.success
        case .offline:    return MobileTheme.Colors.textMuted
        case .pending:    return MobileTheme.amber
        case .unauthorized: return MobileTheme.warning
        case .revoked:    return MobileTheme.error
        case .degraded:   return MobileTheme.warning
        }
    }

    var modelsSection: some View {
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

    func modelRow(_ option: HermesRuntimeModelOption) -> some View {
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

    var displaySection: some View {
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
                        Text("Hermes assistant messages render markdown emphasis as styled text and `@mentions` / `code spans` as inline chips, with line breaking by Pretext. Error states stay plain.")
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

    var securitySection: some View {
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

    var statusSection: some View {
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

    var addDirectSheet: some View {
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

    func sectionTitle(_ title: String, icon: String, color: Color) -> some View {
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

    func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(MobileTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    func infoRow(_ label: String, value: String) -> some View {
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

    func infoRow(_ label: String, value: Date, style: Text.DateStyle) -> some View {
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

    var urlBinding: Binding<String> {
        Binding(
            get: { service.selectedConnection.endpointURL ?? "http://localhost:8642" },
            set: { _ in
                // Update the selected connection's endpoint URL
                // This is a mutable property on the service's selectedConnection
                // In practice, HermesService manages this via its own persistence
            }
        )
    }

    var tokenBinding: Binding<String> {
        Binding(
            get: { "" },
            set: { _ in }
        )
    }

    var modelBinding: Binding<String> {
        Binding(
            get: { "" },
            set: { _ in }
        )
    }

    var relayBinding: Binding<Bool> {
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

    var deleteBinding: Binding<Bool> {
        Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )
    }

    var canonicalGatewayPairingCode: String? {
        HermesGatewayPairingCodeFormatter.canonicalCode(from: gatewayPairingCode)
    }

    var shouldUseGatewayModelPicker: Bool {
        !gatewayStore.activeClients.isEmpty && (!service.isReachable || service.modelOptions.isEmpty)
    }

    func presentModelPicker() {
        showModelPicker = true
    }

    var shouldShowGatewayPairingControls: Bool {
        gatewayStore.activeClients.isEmpty || showGatewayAdditionalPairing || !gatewayPairingCode.isEmpty
    }

    static func gatewayDate(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

}

func hermesGatewayNonBlank(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

func hermesGatewayReplyModelProvider(providerID: String?, modelID: String) -> AgentProvider? {
    let normalizedProviderID = hermesGatewayNonBlank(providerID)
    if let providerID = normalizedProviderID,
       let provider = AgentProvider.fromCatalogProviderID(providerID) {
        return provider
    }
    let provider = hermesAgentProvider(
        for: [
            normalizedProviderID,
            hermesGatewayNonBlank(modelID)
        ]
        .compactMap(\.self)
        .joined(separator: " ")
    )
    return provider == AssistantRuntimeID.hermes.agentProvider ? nil : provider
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
