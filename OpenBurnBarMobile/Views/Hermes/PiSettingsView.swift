import SwiftUI
import OpenBurnBarCore

// MARK: - Pi Settings View
//
// Sibling of `HermesSettingsView`. Renders Pi-specific status, hosts, and
// models as a native grouped `Form`, matching Apple's stock Settings styling.

struct PiSettingsView: View {
    @Bindable var service: PiService
    let authStore: AuthStore

    @State private var showConnectionSheet = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(MobileTheme.piGradient)
                            .frame(width: 29, height: 29)
                        Text(AssistantRuntimeID.pi.glyph)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pi")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("AI Environment configuration")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .settingsAnchor(SettingsAnchor.piRow)
            }

            Section {
                if service.isLoadingRuntime {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Probing Pi gateway…")
                            .foregroundStyle(.secondary)
                    }
                } else if service.isReachable {
                    Label("Online", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(MobileTheme.Colors.success)
                } else if let err = service.runtimeErrorText {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(MobileTheme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Pi gateway not reached yet.", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await service.refreshRuntime() }
                } label: {
                    Label("Re-check connection", systemImage: "arrow.clockwise")
                }
                .tint(MobileTheme.whimsy)
            } header: {
                Text("Status")
            }

            Section {
                ForEach(service.connections) { connection in
                    Button {
                        _ = service.selectConnection(connection)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(statusColor(connection.status))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.displayName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(subtitleFor(connection))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if service.selectedConnection.id == connection.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(MobileTheme.whimsy)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button("Change Host…") { showConnectionSheet = true }
                    .tint(MobileTheme.whimsy)
            } header: {
                Text("Hosts")
            }
            .settingsAnchor(SettingsAnchor.piHosts)

            Section {
                if service.modelOptions.isEmpty {
                    Text("No models discovered yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.modelOptions) { option in
                        Button {
                            service.selectModel(option)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if service.selectedModelID == option.modelID {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(MobileTheme.whimsy)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Models")
            }
            .settingsAnchor(SettingsAnchor.piModels)
        }
        .navigationTitle("Pi")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnectionSheet) {
            AssistantConnectionSheet(
                hermesService: nil,
                piService: service,
                focusedRuntime: .pi
            )
        }
        .task { await service.refreshRuntime() }
    }

    // MARK: - Helpers

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
