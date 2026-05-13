import SwiftUI
import OpenBurnBarCore

// MARK: - Assistant Connection Sheet
//
// One sheet, four sections (Plan 2 §6):
//   1. Hermes Hosts
//   2. Pi Hosts
//   3. Direct URL (per-runtime)
//   4. This Device (local availability)
//
// Selecting a Hermes row mutates only `hermesService.selectedConnection`;
// selecting a Pi row mutates only `piService.selectedConnection`. Cross-runtime
// independence is guaranteed by construction.

struct AssistantConnectionSheet: View {
    let hermesService: HermesService?
    let piService: PiService?
    let focusedRuntime: AssistantRuntimeID

    @Environment(\.dismiss) private var dismiss
    @State private var directRuntime: AssistantRuntimeID
    @State private var directName: String = ""
    @State private var directURL: String = ""
    @State private var directBearer: String = ""

    init(
        hermesService: HermesService?,
        piService: PiService?,
        focusedRuntime: AssistantRuntimeID
    ) {
        self.hermesService = hermesService
        self.piService = piService
        self.focusedRuntime = focusedRuntime
        _directRuntime = State(initialValue: focusedRuntime)
    }

    var body: some View {
        NavigationStack {
            List {
                hermesSection
                piSection
                directURLSection
                thisDeviceSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MobileTheme.Colors.background)
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Hermes section

    @ViewBuilder
    private var hermesSection: some View {
        if let hermesService {
            Section {
                if hermesService.connections.isEmpty {
                    Text("No Hermes hosts yet.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } else {
                    ForEach(hermesService.connections) { connection in
                        hermesRow(connection)
                    }
                }
            } header: {
                sectionLabel("Hermes Hosts", glyph: AssistantRuntimeID.hermes.glyph, tint: MobileTheme.hermesAureate)
            }
        }
    }

    private func hermesRow(_ connection: HermesConnectionRecord) -> some View {
        let isSelected = hermesService?.selectedConnection.id == connection.id
        return Button {
            _ = hermesService?.selectConnection(connection)
        } label: {
            HStack(spacing: MobileTheme.Spacing.md) {
                statusDot(color: hermesStatusColor(connection.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(connectionSubtitle(modeLabel: hermesModeLabel(connection.mode), endpoint: connection.endpointURL, status: connection.status.rawValue))
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MobileTheme.mercuryGradient)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pi section

    @ViewBuilder
    private var piSection: some View {
        if let piService {
            Section {
                if piService.connections.isEmpty {
                    Text("No Pi hosts yet.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } else {
                    ForEach(piService.connections) { connection in
                        piRow(connection, service: piService)
                    }
                }
            } header: {
                sectionLabel("Pi Hosts", glyph: AssistantRuntimeID.pi.glyph, tint: MobileTheme.whimsy)
            }
        }
    }

    private func piRow(_ connection: PiConnectionRecord, service: PiService) -> some View {
        let isSelected = service.selectedConnection.id == connection.id
        return Button {
            _ = service.selectConnection(connection)
        } label: {
            HStack(spacing: MobileTheme.Spacing.md) {
                statusDot(color: piStatusColor(connection.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(connectionSubtitle(modeLabel: piModeLabel(connection.mode), endpoint: connection.endpointURL, status: connection.status.rawValue))
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MobileTheme.piGradient)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Direct URL section

    private var directURLSection: some View {
        Section {
            Picker("Runtime", selection: $directRuntime) {
                ForEach(AssistantRuntimeID.allCases, id: \.self) { runtime in
                    Text("\(runtime.glyph) \(runtime.displayName)").tag(runtime)
                }
            }
            .pickerStyle(.segmented)

            TextField("Name (e.g. Home Mac)", text: $directName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            TextField(directRuntime.defaultGatewayURL.absoluteString, text: $directURL)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("Bearer token (optional)", text: $directBearer)
                .textFieldStyle(.roundedBorder)

            Button {
                addDirect()
            } label: {
                Label("Add direct URL", systemImage: "plus.circle.fill")
            }
            .disabled(directName.isEmpty || directURL.isEmpty)
        } header: {
            sectionLabel("Direct URL", glyph: "link", tint: MobileTheme.amber, isSymbol: true)
        }
    }

    private func addDirect() {
        switch directRuntime {
        case .hermes:
            // Hermes direct URL adds happen through HermesService's own
            // pairing flow today; keep this branch as a no-op so the
            // segmented picker stays usable but doesn't double-write.
            break
        case .pi:
            _ = piService?.addDirectConnection(
                name: directName,
                urlString: directURL,
                bearerToken: directBearer.isEmpty ? nil : directBearer
            )
        case .codex, .claude, .openClaw:
            // Bridged runtimes are paired via the macOS host — direct URL
            // entry from mobile is intentionally a no-op for now.
            break
        }
        directName = ""
        directURL = ""
        directBearer = ""
    }

    // MARK: - This Device section

    private var thisDeviceSection: some View {
        Section {
            HStack(spacing: MobileTheme.Spacing.md) {
                runtimePresenceRow(
                    runtime: .hermes,
                    label: "Hermes",
                    isReady: hermesService?.isReachable ?? false,
                    tint: MobileTheme.hermesAureate
                )
                Divider().frame(height: 28)
                runtimePresenceRow(
                    runtime: .pi,
                    label: "Pi",
                    isReady: piService?.isReachable ?? false,
                    tint: MobileTheme.whimsy
                )
            }
        } header: {
            sectionLabel("This Device", glyph: "iphone", tint: MobileTheme.Colors.textSecondary, isSymbol: true)
        }
    }

    private func runtimePresenceRow(runtime: AssistantRuntimeID, label: String, isReady: Bool, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(isReady ? MobileTheme.Colors.success : MobileTheme.Colors.textMuted).frame(width: 8, height: 8)
                Text(label).font(MobileTheme.Typography.body).foregroundStyle(MobileTheme.Colors.textPrimary)
            }
            Text(isReady ? "Ready" : "Not reachable")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String, glyph: String, tint: Color, isSymbol: Bool = false) -> some View {
        HStack(spacing: 6) {
            if isSymbol {
                Image(systemName: glyph).font(.system(size: 11, weight: .semibold))
            } else {
                Text(glyph).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            Text(title).font(MobileTheme.Typography.caption.bold())
        }
        .foregroundStyle(tint)
    }

    private func statusDot(color: Color) -> some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }

    private func connectionSubtitle(modeLabel: String, endpoint: String?, status: String) -> String {
        var parts: [String] = [modeLabel]
        if let endpoint, !endpoint.isEmpty { parts.append(endpoint) }
        parts.append(status.capitalized)
        return parts.joined(separator: " · ")
    }

    private func hermesStatusColor(_ status: HermesConnectionStatus) -> Color {
        switch status {
        case .online: return MobileTheme.Colors.success
        case .pending, .degraded: return MobileTheme.Colors.warning
        case .offline: return MobileTheme.Colors.textMuted
        case .unauthorized, .revoked: return MobileTheme.Colors.error
        }
    }

    private func piStatusColor(_ status: PiConnectionStatus) -> Color {
        switch status {
        case .online: return MobileTheme.Colors.success
        case .pending, .degraded: return MobileTheme.Colors.warning
        case .offline: return MobileTheme.Colors.textMuted
        case .unauthorized, .revoked: return MobileTheme.Colors.error
        }
    }

    private func hermesModeLabel(_ mode: HermesConnectionMode) -> String {
        switch mode {
        case .local: return "Local"
        case .directURL: return "Direct"
        case .relayLink: return "Relay"
        }
    }

    private func piModeLabel(_ mode: PiConnectionMode) -> String {
        switch mode {
        case .local: return "Local"
        case .directURL: return "Direct"
        case .relayLink: return "Relay"
        }
    }
}
