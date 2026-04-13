import SwiftUI

struct DaemonSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore

    init(
        settingsManager: SettingsManager,
        daemonManager: OpenBurnBarDaemonManager = .shared,
        dataStore: DataStore
    ) {
        self._settingsManager = Bindable(settingsManager)
        self._daemonManager = Bindable(daemonManager)
        self.dataStore = dataStore
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                SettingsSectionHeader(title: "Daemon Lifecycle")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(daemonManager.status.label)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text(daemonManager.detailText)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            Spacer()
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Button("Refresh") {
                                    Task { await daemonManager.refreshHealth() }
                                }
                                .buttonStyle(.bordered)

                                Button(primaryActionTitle) {
                                    Task {
                                        switch daemonManager.status {
                                        case .healthy:
                                            await daemonManager.repair()
                                        case .checking:
                                            await daemonManager.refreshHealth()
                                        case .notInstalled, .unhealthy:
                                            await daemonManager.installAndStart()
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                        Divider().background(DesignSystem.Colors.border)

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            detailRow(label: "Socket", value: daemonManager.socketPathDisplay)
                            detailRow(label: "Runtime source", value: daemonManager.runtimeStateSource.detailText)
                            detailRow(label: "Recent daemon events", value: daemonManager.recentEvents.isEmpty ? "No recent log lines." : daemonManager.recentEvents.joined(separator: "\n"))
                        }

                        if let lastError = daemonManager.lastError, lastError.isEmpty == false {
                            Divider().background(DesignSystem.Colors.border)
                            Text(lastError)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.error)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                SettingsSectionHeader(title: "HTTP Gateway")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        SettingsToggle(
                            title: "Enable HTTP gateway",
                            subtitle: "Expose an OpenAI-compatible API on a local port for external tools (like Vibe Proxy on 8317).",
                            icon: "network",
                            isOn: $settingsManager.gatewayEnabled
                        )

                        if settingsManager.gatewayEnabled {
                            Divider().background(DesignSystem.Colors.border)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Host")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    Text("Bind address for the gateway server")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                TextField("127.0.0.1", text: $settingsManager.gatewayHost)
                                    .textFieldStyle(.roundedBorder)
                                    .font(DesignSystem.Typography.monoSmall)
                                    .frame(width: 140)
                            }

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Port")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    Text("Port number for the gateway")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                TextField("8317", value: $settingsManager.gatewayPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .font(DesignSystem.Typography.monoSmall)
                                    .frame(width: 80)
                            }

                            let isLoopback = settingsManager.gatewayHost == "127.0.0.1"
                                || settingsManager.gatewayHost == "localhost"
                                || settingsManager.gatewayHost == "::1"

                            if !isLoopback {
                                Divider().background(DesignSystem.Colors.border)

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Auth token")
                                            .font(DesignSystem.Typography.caption)
                                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                                        Text("Required for non-loopback bindings")
                                            .font(DesignSystem.Typography.tiny)
                                            .foregroundStyle(DesignSystem.Colors.warning)
                                    }
                                    Spacer()
                                    SecureField("Bearer token", text: $settingsManager.gatewayAuthToken)
                                        .textFieldStyle(.roundedBorder)
                                        .font(DesignSystem.Typography.monoSmall)
                                        .frame(width: 180)
                                }
                            }

                            if settingsManager.gatewayEnabled {
                                Divider().background(DesignSystem.Colors.border)

                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(DesignSystem.Colors.amber)
                                    Text("Gateway changes require daemon restart to take effect.")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                SettingsSectionHeader(title: "Controller Runtime")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        SettingsToggle(
                            title: "Enable controller runtime",
                            subtitle: "Keep the daemon-backed missions, followups, questions, and replay state active in OpenBurnBar.",
                            icon: "cpu",
                            isOn: $settingsManager.controllerRuntimeEnabled
                        )

                        Divider().background(DesignSystem.Colors.border)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Refresh cadence")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                Text("How often OpenBurnBar refreshes the mirrored controller runtime.")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            Spacer()
                            Picker("", selection: $settingsManager.controllerRuntimeRefreshMinutes) {
                                ForEach([1, 2, 5, 10, 15, 30], id: \.self) { minutes in
                                    Text("\(minutes) min").tag(minutes)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 110)
                        }

                        Divider().background(DesignSystem.Colors.border)

                        SettingsToggle(
                            title: "Simulator tools",
                            subtitle: "Expose replay and simulator controls in operator surfaces.",
                            icon: "play.square.stack",
                            isOn: $settingsManager.controllerSimulatorToolsEnabled
                        )
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .task {
            daemonManager.attach(dataStore: dataStore)
            await daemonManager.refreshHealth()
        }
    }

    private var primaryActionTitle: String {
        switch daemonManager.status {
        case .healthy:
            return "Repair"
        case .checking:
            return "Check"
        case .notInstalled:
            return "Install"
        case .unhealthy:
            return "Repair"
        }
    }
}

private func detailRow(label: String, value: String) -> some View {
    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
        Text(label)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .frame(width: 88, alignment: .leading)

        Text(value)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .textSelection(.enabled)

        Spacer(minLength: 0)
    }
}
