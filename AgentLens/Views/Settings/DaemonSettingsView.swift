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
                    MCPServersSettingsView()
                } label: {
                    SettingsDrillRow(
                        icon: "puzzlepiece.extension.fill",
                        iconTint: DesignSystem.Colors.ember,
                        title: "MCP Servers",
                        subtitle: "Local, daemon, and hosted MCP connections",
                        value: "Manage"
                    )
                }
            } header: {
                Text("MCP")
            }

            Section {
                NavigationLink {
                    HTTPGatewayDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "network",
                        iconTint: DesignSystem.Colors.amber,
                        title: "HTTP Gateway",
                        subtitle: "Local gateway used by Connections. Most users don't need to touch this.",
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
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) {
                            statusTextColumn
                            Spacer()
                            statusActionButtons
                        }

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            statusTextColumn
                            statusActionButtons
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
                    } else if case .retrying(let n, let nextRetry, _) = daemonManager.supervisionState {
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

    @ViewBuilder private var statusTextColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(daemonManager.status.label)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(daemonManager.detailText)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    @ViewBuilder private var statusActionButtons: some View {
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
            subtitle: "Expose OpenBurnBar's OpenAI-compatible Hydrant API on a local port for external tools.",
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
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: DesignSystem.Spacing.sm)
                            TextField("127.0.0.1", text: $settingsManager.gatewayHost)
                                .textFieldStyle(.roundedBorder)
                                .font(DesignSystem.Typography.monoSmall)
                                .frame(minWidth: 96, idealWidth: 140, maxWidth: 140)
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
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: DesignSystem.Spacing.sm)
                            TextField("8317", value: $settingsManager.gatewayPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(DesignSystem.Typography.monoSmall)
                                .frame(minWidth: 64, idealWidth: 80, maxWidth: 80)
                                .focused($focus, equals: .port)
                        }
                        .settingsAnchor(SettingsAnchor.gatewayPort)

                        let isLoopback = settingsManager.gatewayHost == "127.0.0.1"
                            || settingsManager.gatewayHost == "localhost"
                            || settingsManager.gatewayHost == "::1"

                        Divider().background(DesignSystem.Colors.border)

                        SettingsToggle(
                            title: "Allow unauthenticated loopback",
                            subtitle: "Bind 127.0.0.1 without a bearer token. Unsafe: any process on this Mac can spend your provider credits through the gateway.",
                            icon: "lock.open",
                            isOn: $settingsManager.gatewayAllowUnauthenticatedLoopback
                        )
                        .settingsAnchor(SettingsAnchor.gatewayAllowUnauthenticatedLoopback)

                        // Auth is required whenever the gateway is enabled, unless
                        // the user explicitly opted into an unauthenticated loopback
                        // bind. A token is auto-generated on the next daemon launch
                        // when this field is left blank.
                        if !(isLoopback && settingsManager.gatewayAllowUnauthenticatedLoopback) {
                            Divider().background(DesignSystem.Colors.border)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Auth token")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    Text(settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "Auto-generated on next daemon launch"
                                        : "Bearer token clients must send as Authorization: Bearer")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: DesignSystem.Spacing.sm)
                                SecureField("Auto-generated", text: $settingsManager.gatewayAuthToken)
                                    .textFieldStyle(.roundedBorder)
                                    .font(DesignSystem.Typography.monoSmall)
                                    .frame(minWidth: 120, idealWidth: 180, maxWidth: 180)
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

// MARK: - MCP server registry + settings (E1/E3)

enum MCPServerKind: String, Codable, CaseIterable, Sendable {
    case localStdio, daemonSocket, hostedRemote, customStdio
}

struct MCPServerRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: MCPServerKind
    var enabled: Bool
    var command: String?
    var args: [String]
    var envKeys: [String]
    var url: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: MCPServerKind,
        enabled: Bool = true,
        command: String? = nil,
        args: [String] = [],
        envKeys: [String] = [],
        url: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.command = command
        self.args = args
        self.envKeys = envKeys
        self.url = url
    }
}

struct MCPServerRegistryFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var servers: [MCPServerRecord]

    init(schemaVersion: Int = Self.currentSchemaVersion, servers: [MCPServerRecord] = Self.defaultServers) {
        self.schemaVersion = schemaVersion
        self.servers = servers
    }

    static let defaultServers: [MCPServerRecord] = [
        MCPServerRecord(name: "OpenBurnBar Local", kind: .localStdio, command: "openburnbar-mcp"),
        MCPServerRecord(name: "OpenBurnBar Daemon", kind: .daemonSocket),
        MCPServerRecord(name: "OpenBurnBar Hosted", kind: .hostedRemote, url: "https://mcp.burnbar.ai/mcp")
    ]
}

struct MCPServerRegistry: Sendable {
    let fileURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let dir = homeDirectory.appendingPathComponent(".openburnbar", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("mcp-servers.json")
    }

    func load() -> MCPServerRegistryFile {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(MCPServerRegistryFile.self, from: data),
              decoded.schemaVersion == MCPServerRegistryFile.currentSchemaVersion else {
            return MCPServerRegistryFile()
        }
        return decoded
    }

    func save(_ file: MCPServerRegistryFile) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload = file
        payload.schemaVersion = MCPServerRegistryFile.currentSchemaVersion
        try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum MCPServerHealthState: String, Sendable {
    case healthy, degraded, unreachable, unknown
}

struct MCPServerHealth: Equatable, Sendable {
    let serverID: String
    let state: MCPServerHealthState
    let detail: String
    let checkedAt: Date
}

struct MCPServerStatusService: Sendable {
    func status(for server: MCPServerRecord, now: Date = Date()) -> MCPServerHealth {
        guard server.enabled else {
            return MCPServerHealth(serverID: server.id, state: .degraded, detail: "Disabled", checkedAt: now)
        }
        switch server.kind {
        case .daemonSocket:
            return MCPServerHealth(serverID: server.id, state: .unknown, detail: "Daemon socket probe pending", checkedAt: now)
        case .hostedRemote:
            let vaultPresent = FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".openburnbar/vault-key").path
            )
            return MCPServerHealth(
                serverID: server.id,
                state: vaultPresent ? .healthy : .degraded,
                detail: vaultPresent ? "Vault key present" : "Vault key missing",
                checkedAt: now
            )
        case .localStdio, .customStdio:
            return MCPServerHealth(serverID: server.id, state: .unknown, detail: "Stdio probe not run", checkedAt: now)
        }
    }
}

@Observable @MainActor
final class MCPServersSettingsModel {
    private(set) var servers: [MCPServerRecord] = []
    private(set) var healthByID: [String: MCPServerHealth] = [:]
    private(set) var errorMessage: String?

    private let registry: MCPServerRegistry
    private let statusService: MCPServerStatusService

    init(registry: MCPServerRegistry = MCPServerRegistry(), statusService: MCPServerStatusService = MCPServerStatusService()) {
        self.registry = registry
        self.statusService = statusService
    }

    func load() {
        servers = registry.load().servers
        refreshHealth()
    }

    func refreshHealth() {
        let now = Date()
        healthByID = Dictionary(uniqueKeysWithValues: servers.map { server in
            (server.id, statusService.status(for: server, now: now))
        })
    }

    func setEnabled(serverID: String, enabled: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].enabled = enabled
        persist()
    }

    func remove(serverID: String) {
        servers.removeAll { $0.id == serverID }
        persist()
    }

    private func persist() {
        do {
            try registry.save(MCPServerRegistryFile(servers: servers))
            errorMessage = nil
            refreshHealth()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not save MCP servers."
        }
    }
}

struct MCPServersSettingsView: View {
    @State private var model = MCPServersSettingsModel()

    var body: some View {
        List {
            if let errorMessage = model.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(model.servers, id: \.id) { server in
                HStack {
                    Circle()
                        .fill(statusColor(model.healthByID[server.id]?.state ?? .unknown))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).font(.headline)
                        Text(server.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                        if let detail = model.healthByID[server.id]?.detail {
                            Text(detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(
                        get: { server.enabled },
                        set: { model.setEnabled(serverID: server.id, enabled: $0) }
                    ))
                    .labelsHidden()
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    model.remove(serverID: model.servers[index].id)
                }
            }
        }
        .navigationTitle("MCP Servers")
        .task { model.load() }
    }

    private func statusColor(_ state: MCPServerHealthState) -> Color {
        switch state {
        case .healthy: return .green
        case .degraded: return .orange
        case .unreachable: return .red
        case .unknown: return .gray
        }
    }
}
