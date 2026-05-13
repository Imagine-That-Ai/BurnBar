import SwiftUI

// MARK: - Daemon Settings (iOS-style landing)

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
        List {
            Section {
                NavigationLink {
                    DaemonLifecycleDetailView(daemonManager: daemonManager)
                } label: {
                    SettingsDrillRow(
                        icon: "cpu.fill",
                        iconTint: DesignSystem.Colors.teal,
                        title: "Lifecycle & Health",
                        subtitle: "Install, repair, and watch the local daemon",
                        value: daemonManager.status.label,
                        valueTint: statusTint
                    )
                }
            } header: {
                Text("Daemon")
            } footer: {
                Text("The daemon runs locally on this Mac and brokers requests for routed providers and the controller runtime.")
                    .font(DesignSystem.Typography.tiny)
            }

            Section {
                NavigationLink {
                    HTTPGatewayDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "network",
                        iconTint: DesignSystem.Colors.amber,
                        title: "HTTP Gateway",
                        subtitle: "Expose an OpenAI-compatible API for external tools",
                        value: settingsManager.gatewayEnabled ? gatewayEndpoint : "Off",
                        valueTint: settingsManager.gatewayEnabled
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted
                    )
                }

                NavigationLink {
                    ControllerRuntimeDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "rectangle.connected.to.line.below",
                        iconTint: DesignSystem.Colors.purple,
                        title: "Controller Runtime",
                        subtitle: "Mirror daemon missions, followups, and replay state",
                        value: settingsManager.controllerRuntimeEnabled
                            ? "Every \(settingsManager.controllerRuntimeRefreshMinutes) min"
                            : "Off",
                        valueTint: settingsManager.controllerRuntimeEnabled
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted
                    )
                }
            } header: {
                Text("Gateways & runtime")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
        .navigationTitle("Daemon")
        .task {
            daemonManager.attach(dataStore: dataStore)
            await daemonManager.refreshHealth()
        }
    }

    private var statusTint: Color {
        switch daemonManager.status {
        case .healthy: return DesignSystem.Colors.success
        case .checking: return DesignSystem.Colors.textSecondary
        case .notInstalled, .unhealthy: return DesignSystem.Colors.error
        }
    }

    private var gatewayEndpoint: String {
        "\(settingsManager.gatewayHost):\(settingsManager.gatewayPort)"
    }
}

// MARK: - Daemon Lifecycle Detail

struct DaemonLifecycleDetailView: View {
    @Bindable var daemonManager: OpenBurnBarDaemonManager

    var body: some View {
        SettingsDetailContainer(
            title: "Lifecycle & Health",
            subtitle: "Manage the OpenBurnBar daemon process: install it, repair it, and watch recent events.",
            searchRoute: .daemonLifecycle
        ) {
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
                        detailRow(
                            label: "Recent events",
                            value: daemonManager.recentEvents.isEmpty
                                ? "No recent log lines."
                                : daemonManager.recentEvents.joined(separator: "\n")
                        )
                    }

                    if let lastError = daemonManager.lastError, !lastError.isEmpty {
                        Divider().background(DesignSystem.Colors.border)
                        Text(lastError)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.error)
                            .textSelection(.enabled)
                    }

                    if case .crashLoop = daemonManager.supervisionState {
                        Divider().background(DesignSystem.Colors.border)
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DesignSystem.Colors.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Daemon crash loop detected")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text("The daemon has failed \(daemonManager.supervisionState.consecutiveFailures) consecutive times. Click Repair to reinstall and restart.")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }
                    } else if case .retrying(let n, let nextRetry) = daemonManager.supervisionState {
                        Divider().background(DesignSystem.Colors.border)
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Retrying daemon health check")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                Text("Attempt \(n + 1) — next check at \(nextRetry, style: .time)")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
                .settingsAnchor(SettingsAnchor.daemonStatus)
            }
        }
    }

    private var primaryActionTitle: String {
        switch daemonManager.status {
        case .healthy: return "Repair"
        case .checking: return "Check"
        case .notInstalled: return "Install"
        case .unhealthy: return "Repair"
        }
    }
}

// MARK: - HTTP Gateway Detail

struct HTTPGatewayDetailView: View {
    @Bindable var settingsManager: SettingsManager
    @Environment(SettingsRouter.self) private var router: SettingsRouter?

    private enum Focus: Hashable {
        case host, port, authToken
    }

    @FocusState private var focus: Focus?

    var body: some View {
        SettingsDetailContainer(
            title: "HTTP Gateway",
            subtitle: "Expose an OpenAI-compatible API on a local port for external tools (Vibe Proxy on 8317 is the typical setup).",
            searchRoute: .httpGateway
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Enable HTTP gateway",
                        subtitle: "Listens for OpenAI-compatible requests on the configured host and port.",
                        icon: "network",
                        isOn: $settingsManager.gatewayEnabled
                    )
                    .settingsAnchor(SettingsAnchor.gatewayEnabled)

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
                                .focused($focus, equals: .host)
                        }
                        .settingsAnchor(SettingsAnchor.gatewayHost)

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
                                .focused($focus, equals: .port)
                        }
                        .settingsAnchor(SettingsAnchor.gatewayPort)

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
                                    .focused($focus, equals: .authToken)
                            }
                            .settingsAnchor(SettingsAnchor.gatewayAuthToken)
                        }

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
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .onAppear { applyPendingFocus() }
        .onChange(of: router?.pendingFocus) { _, _ in applyPendingFocus() }
    }

    private func applyPendingFocus() {
        guard let router else { return }
        guard let pending = router.pendingFocus else { return }
        let target: Focus?
        switch pending {
        case SettingsFocus.gatewayHost: target = .host
        case SettingsFocus.gatewayPort: target = .port
        case SettingsFocus.gatewayAuthToken: target = .authToken
        default: target = nil
        }
        guard let resolved = target else { return }
        // Delay a tick so the field is in the hierarchy before focusing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focus = resolved
            router.consumePendingFocus(pending)
        }
    }
}

// MARK: - Controller Runtime Detail

struct ControllerRuntimeDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Controller Runtime",
            subtitle: "Keep daemon-backed missions, followups, questions, and replay state mirrored into the OpenBurnBar UI.",
            searchRoute: .controllerRuntime
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Enable controller runtime",
                        subtitle: "When off, the dashboard mission surfaces stop polling the daemon.",
                        icon: "cpu",
                        isOn: $settingsManager.controllerRuntimeEnabled
                    )
                    .settingsAnchor(SettingsAnchor.controllerEnabled)

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
                    .settingsAnchor(SettingsAnchor.controllerRefresh)

                    Divider().background(DesignSystem.Colors.border)

                    SettingsToggle(
                        title: "Simulator tools",
                        subtitle: "Expose replay and simulator controls in operator surfaces.",
                        icon: "play.square.stack",
                        isOn: $settingsManager.controllerSimulatorToolsEnabled
                    )
                    .settingsAnchor(SettingsAnchor.controllerSimulator)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Helpers

private func detailRow(label: String, value: String) -> some View {
    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
        Text(label)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .frame(width: 100, alignment: .leading)

        Text(value)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .textSelection(.enabled)

        Spacer(minLength: 0)
    }
}
