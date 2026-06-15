import SwiftUI
import AVFoundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// Connection, gateway model-picker, runtime sheets + service/option helpers.
// Extracted from HermesTabView.swift (god-file decomposition) — same module, verbatim.

struct HermesConnectionSheet: View {
    @Bindable var service: HermesService
    let gatewayStore: HermesGatewaySettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var endpointURL = ""
    @State private var bearerToken = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)

                ScrollView {
                    VStack(spacing: 20) {
                        // 1. Suggested Mac Relay Banner (Clean & Contextual)
                        if let relay = service.suggestedRelayConnection,
                           service.selectedConnection.id != relay.id {
                            AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.standardCorner) {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "macbook.and.iphone")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(MobileTheme.hermesAureate)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Mac Relay Available")
                                                .font(MobileTheme.Typography.body)
                                                .fontWeight(.bold)
                                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                                            Text("Connect to your signed-in Mac to access Hermes.")
                                                .font(MobileTheme.Typography.caption)
                                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        }
                                    }

                                    Button {
                                        if service.connectToSuggestedRelay() {
                                            dismiss()
                                        } else {
                                            errorText = service.lastError
                                        }
                                    } label: {
                                        Text("Connect to \(relay.displayName)")
                                            .font(MobileTheme.Typography.body)
                                            .fontWeight(.semibold)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.aurora(.hermes, fullWidth: true))
                                }
                            }
                        }

                        // 2. Error Display Cards
                        if let runtimeErrorText = service.runtimeErrorText {
                            AuroraGlassCard(variant: .urgent, cornerRadius: AuroraDesign.Shape.standardCorner) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(MobileTheme.error)
                                        Text("Connection Status")
                                            .font(MobileTheme.Typography.body)
                                            .fontWeight(.bold)
                                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    }
                                    Text(runtimeErrorText)
                                        .font(MobileTheme.Typography.caption)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)

                                    Button {
                                        Task { await service.refreshConnections() }
                                    } label: {
                                        Text("Retry Discovery")
                                            .font(MobileTheme.Typography.caption)
                                            .fontWeight(.semibold)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.aurora(.hermes, fullWidth: true))
                                    .padding(.top, 4)
                                }
                            }
                        }

                        if let errorText {
                            AuroraGlassCard(variant: .urgent, cornerRadius: AuroraDesign.Shape.standardCorner) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Action Error")
                                        .font(MobileTheme.Typography.caption)
                                        .fontWeight(.bold)
                                        .foregroundStyle(MobileTheme.error)
                                    Text(errorText)
                                        .font(MobileTheme.Typography.caption)
                                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                                }
                            }
                        }

                        if !gatewayStore.activeClients.isEmpty {
                            burnBarGatewayConnectionCard
                        }

                        // 3. Active Hosts Section
                        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 8) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(MobileTheme.hermesAureate)
                                    Text("Available Hosts")
                                        .font(MobileTheme.Typography.headline)
                                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    Spacer()
                                }
                                .padding(.bottom, 2)

                                VStack(spacing: 0) {
                                    ForEach(Array(service.connections.enumerated()), id: \.element.id) { index, connection in
                                        let isSelected = connection.id == service.selectedConnection.id
                                        VStack(spacing: 0) {
                                            HStack(spacing: 12) {
                                                Button {
                                                    if service.selectConnection(connection) {
                                                        dismiss()
                                                    } else {
                                                        errorText = service.lastError
                                                    }
                                                } label: {
                                                    HStack(spacing: 12) {
                                                        // Glowing status dot
                                                        ZStack {
                                                            Circle()
                                                                .fill(connection.status == .online ? MobileTheme.success : MobileTheme.warning)
                                                                .frame(width: 8, height: 8)
                                                            if connection.status == .online {
                                                                Circle()
                                                                    .stroke(MobileTheme.success.opacity(0.4), lineWidth: 1.5)
                                                                    .frame(width: 14, height: 14)
                                                            }
                                                        }
                                                        .frame(width: 16, height: 16)

                                                        VStack(alignment: .leading, spacing: 2) {
                                                            Text(connection.displayName)
                                                                .font(MobileTheme.Typography.body)
                                                                .fontWeight(.semibold)
                                                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                                                            Text(connectionSubtitle(connection))
                                                                .font(MobileTheme.Typography.tiny)
                                                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                                        }
                                                        Spacer()
                                                    }
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)

                                                if isSelected {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 18))
                                                        .foregroundStyle(MobileTheme.hermesAureate)
                                                }

                                                if connection.id != HermesConnectionRecord.localDefault.id {
                                                    Button {
                                                        Task { await revoke(connection) }
                                                    } label: {
                                                        Image(systemName: "trash")
                                                            .font(.system(size: 13, weight: .medium))
                                                            .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.6))
                                                            .padding(6)
                                                            .background(Circle().fill(MobileTheme.Colors.surface.opacity(0.4)))
                                                    }
                                                    .buttonStyle(.plain)
                                                    .padding(.leading, 4)
                                                }
                                            }
                                            .padding(.vertical, 10)

                                            if index < service.connections.count - 1 {
                                                Divider()
                                                    .background(MobileTheme.Colors.border.opacity(0.3))
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 4. Add Direct Host Section
                        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 8) {
                                    Image(systemName: "link.badge.plus")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(MobileTheme.hermesAureate)
                                    Text("Add Direct Host")
                                        .font(MobileTheme.Typography.headline)
                                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    Spacer()
                                }
                                .padding(.bottom, 2)

                                VStack(alignment: .leading, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Host Name")
                                            .font(MobileTheme.Typography.tiny)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        TextField("e.g. Home Mac", text: $displayName)
                                            .font(MobileTheme.Typography.body)
                                            .padding(12)
                                            .background(MobileTheme.Colors.surface.opacity(0.35))
                                            .cornerRadius(10)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.8)
                                            )
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Hermes URL")
                                            .font(MobileTheme.Typography.tiny)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        TextField("http://192.168.1.2:8642", text: $endpointURL)
                                            .font(MobileTheme.Typography.body)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .padding(12)
                                            .background(MobileTheme.Colors.surface.opacity(0.35))
                                            .cornerRadius(10)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.8)
                                            )
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("API Server Key (optional)")
                                            .font(MobileTheme.Typography.tiny)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        SecureField("Bearer token key", text: $bearerToken)
                                            .font(MobileTheme.Typography.body)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .padding(12)
                                            .background(MobileTheme.Colors.surface.opacity(0.35))
                                            .cornerRadius(10)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.8)
                                            )
                                    }

                                    if !endpointURL.isEmpty, HermesService.validatedEndpointURL(endpointURL) == nil {
                                        Text("Use HTTPS, or HTTP only for localhost/private LAN Hermes hosts.")
                                            .font(MobileTheme.Typography.tiny)
                                            .foregroundStyle(MobileTheme.error)
                                    }

                                    Button {
                                        Task { await addDirectConnection() }
                                    } label: {
                                        if isWorking {
                                            ProgressView()
                                                .tint(.white)
                                                .frame(maxWidth: .infinity)
                                        } else {
                                            Text("Register and Connect")
                                                .font(MobileTheme.Typography.body)
                                                .fontWeight(.bold)
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                    .buttonStyle(.aurora(.hermes, fullWidth: true))
                                    .disabled(isWorking || displayName.isEmpty || HermesService.validatedEndpointURL(endpointURL) == nil)
                                    .padding(.top, 6)
                                }
                            }
                        }

                        // 5. Secure Storage Footnote
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 11))
                            Text("API keys stay securely stored locally on this device.")
                                .font(MobileTheme.Typography.tiny)
                        }
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                    }
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Hermes Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await service.refreshConnections() }
        }
    }

    private var burnBarGatewayConnectionCard: some View {
        let onlineCount = gatewayStore.onlineClients.count
        let activeCount = gatewayStore.activeClients.count
        let selectedClient = gatewayStore.selectedClient
        let isOnline = selectedClient.map { gatewayStore.isOnline($0) } ?? (onlineCount > 0)

        return AuroraGlassCard(variant: isOnline ? .success : .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill((isOnline ? MobileTheme.success : MobileTheme.warning).opacity(0.16))
                            .frame(width: 44, height: 44)
                        Image(systemName: isOnline ? "checkmark.seal.fill" : "link.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(isOnline ? MobileTheme.success : MobileTheme.warning)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("BurnBar Cloud Gateway")
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.bold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(gatewayConnectionSheetSubtitle(activeCount: activeCount, onlineCount: onlineCount))
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Text(isOnline ? "Online" : "Paired")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .foregroundStyle(isOnline ? MobileTheme.success : MobileTheme.warning)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill((isOnline ? MobileTheme.success : MobileTheme.warning).opacity(0.12)))
                }

                if let client = selectedClient ?? gatewayStore.onlineClients.first ?? gatewayStore.activeClients.first {
                    HStack(spacing: 8) {
                        Image(systemName: gatewayStore.selectedClient?.id == client.id ? "checkmark.circle.fill" : "iphone")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(gatewayStore.selectedClient?.id == client.id ? MobileTheme.hermesAureate : MobileTheme.Colors.textMuted)
                        Text(client.displayName)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(client.homeDestinationId)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("BurnBar Cloud Gateway. \(gatewayConnectionSheetSubtitle(activeCount: activeCount, onlineCount: onlineCount))")
    }

    private func gatewayConnectionSheetSubtitle(activeCount: Int, onlineCount: Int) -> String {
        if onlineCount > 0 {
            let noun = onlineCount == 1 ? "gateway client is" : "gateway clients are"
            return "\(onlineCount) \(noun) live. This is the official Hermes messaging gateway through BurnBar Cloud."
        }
        let noun = activeCount == 1 ? "gateway client is" : "gateway clients are"
        return "\(activeCount) \(noun) paired, but no gateway has checked in recently. Restart Hermes Gateway on the computer."
    }

    private func addDirectConnection() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await service.addDirectConnection(
                displayName: displayName,
                endpointURL: endpointURL,
                bearerToken: bearerToken
            )
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke(_ connection: HermesConnectionRecord) async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await service.revokeConnection(connection)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func connectionSubtitle(_ connection: HermesConnectionRecord) -> String {
        if connection.mode == .relayLink {
            return "Remote Relay · works over cell signal"
        }
        return connection.endpointURL ?? connection.mode.rawValue
    }
}

struct HermesGatewayModelPickerSheet: View {
    @Bindable var service: HermesService
    @Bindable var gatewayStore: HermesGatewaySettingsStore
    let senderDisplayName: String
    let threadId: String

    @Environment(\.dismiss) private var dismiss
    @State private var customModelID = ""

    private var options: [HermesRuntimeModelOption] {
        gatewayStore.runtimeModelOptions
    }

    private var currentModelText: String {
        FriendlyModelName.format(
            service.selectedModelID
                ?? gatewayStore.runtimeModelId
                ?? "Hermes default"
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusCard
                        customModelCard
                        modelListCard
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Gateway Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusCard: some View {
        let selectedGateway = gatewayStore.selectedClient
        let selectedOnline = selectedGateway.map { gatewayStore.isOnline($0) } ?? false
        return AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            HStack(spacing: 12) {
                Image(systemName: selectedOnline ? "checkmark.seal.fill" : "link.circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(selectedOnline ? MobileTheme.success : MobileTheme.warning)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill((selectedOnline ? MobileTheme.success : MobileTheme.warning).opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentModelText)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.bold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(2)
                    Text(selectedGateway.map { "Switches are sent to \($0.displayName) through BurnBar Cloud and apply before the next queued message in this conversation." } ?? "Switches are sent to the selected Hermes gateway through BurnBar Cloud.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var customModelCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Exact model id", systemImage: "terminal")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                TextField("minimax-m2.7-highspeed", text: $customModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.5), lineWidth: 0.7)
                    )
                    .onSubmit {
                        switchModel(customModelID)
                    }

                Button {
                    switchModel(customModelID)
                } label: {
                    Label(gatewayStore.isSwitchingModel ? "Switching" : "Switch Gateway Model", systemImage: "arrow.left.arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aurora(.hermes, fullWidth: true))
                .disabled(gatewayStore.isSwitchingModel || customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var modelListCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Published by Gateway", systemImage: "cpu")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                    Spacer()
                    Text("\(options.count)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                if options.isEmpty {
                    Text("Hermes has not published a model catalog yet. Restart the gateway after this update, or type an exact model id above.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(options) { option in
                        HermesModelPickerRow(
                            option: option,
                            isSelected: service.selectedModelID == option.modelID || gatewayStore.runtimeModelId == option.modelID,
                            isFavorite: service.isFavoriteModel(option)
                        ) {
                            switchModel(option.modelID)
                        } onToggleFavorite: {
                            service.toggleFavoriteModel(option)
                            HapticBus.toggle()
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func switchModel(_ modelID: String) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Optimistic: select + dismiss immediately. The sealed gateway
        // enqueue is a Firestore round trip (E2EE seal + network) that used
        // to block the tap for seconds; it now rides in the background. If
        // the runtime ends up on a different model, the per-turn
        // "asked X → got Y" honesty badge reports it, and the gateway
        // store's notice surfaces enqueue failures.
        service.selectGatewayModelID(trimmed)
        HapticBus.primaryAction()
        dismiss()
        let store = gatewayStore
        let sender = senderDisplayName
        let thread = threadId
        Task {
            await store.switchGatewayModel(
                modelId: trimmed,
                senderDisplayName: sender,
                threadId: thread
            )
        }
    }
}

struct HermesRuntimeSheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let runtimeErrorText = service.runtimeErrorText {
                    Section {
                        Text(runtimeErrorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                        Button {
                            Task { await service.refreshRuntime() }
                        } label: {
                            Label("Retry Runtime Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section("Models") {
                    if service.modelOptions.isEmpty {
                        Text("No models discovered")
                    } else {
                        ForEach(service.modelOptions) { option in
                            HermesModelPickerRow(
                                option: option,
                                isSelected: service.selectedModelID == option.modelID,
                                isFavorite: service.isFavoriteModel(option)
                            ) {
                                service.selectModel(option)
                                HapticBus.primaryAction()
                                dismiss()
                            } onToggleFavorite: {
                                service.toggleFavoriteModel(option)
                                HapticBus.toggle()
                            }
                        }
                    }
                }

                Section("Profiles") {
                    if service.profiles.isEmpty {
                        Text("No profiles discovered")
                    } else {
                        ForEach(service.profiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(MobileTheme.Typography.body)
                                Text([profile.provider, profile.model].compactMap { $0 }.joined(separator: " · "))
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                            }
                        }
                    }
                }

                Section("Jobs") {
                    if service.jobs.isEmpty {
                        Text("No scheduled jobs discovered")
                    } else {
                        ForEach(service.jobs) { job in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(job.name ?? job.prompt)
                                        .font(MobileTheme.Typography.body)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(job.enabled ? job.state : "disabled")
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(job.enabled ? MobileTheme.success : MobileTheme.Colors.textMuted)
                                }
                                if let nextRunAt = job.nextRunAt {
                                    Text("Next run \(nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hermes Runtime")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await service.refreshRuntime() }
        }
    }
}

extension HermesService {
    var selectedModelOption: HermesRuntimeModelOption? {
        guard let selectedModelID else { return nil }
        let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(
            selectedModelID,
            in: modelOptions
        ) ?? selectedModelID
        return modelOptions.first { $0.modelID == resolved }
    }
}

extension HermesRuntimeModelOption {
    var agentProvider: AgentProvider {
        hermesAgentProvider(for: [providerID, providerName, modelID].joined(separator: " "))
    }
}

func hermesAgentProvider(for raw: String) -> AgentProvider {
    let lower = raw.lowercased()
    if lower.contains("openai") || lower.contains("gpt") { return .openAI }
    if lower.contains("anthropic") || lower.contains("claude") { return .claudeCode }
    if lower.contains("minimax") || lower.contains("abab") { return .minimax }
    if lower.contains("zai") || lower.contains("z.ai") || lower.contains("glm") { return .zai }
    if lower.contains("kimi") || lower.contains("moonshot") { return .kimi }
    if lower.contains("deepseek") { return .deepSeek }
    if lower.contains("antigravity") { return .antigravity }
    if lower.contains("grok") || lower.contains("xai") { return .xAI }
    if lower.contains("google") || lower.contains("gemini") { return .geminiCLI }
    if lower.contains("meta") || lower.contains("llama") || lower.contains("qwen") { return .ollama }
    if lower.contains("codex") { return .codex }
    if lower.contains("hermes") { return .hermes }
    return .openClaw
}
