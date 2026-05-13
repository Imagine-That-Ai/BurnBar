import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Pool model

/// One row in a routing pool: an account, its current health, and whether the
/// router considers it the active lane right now.
private struct PoolAccountRow: Identifiable, Hashable {
    let id: String
    let providerID: ProviderID
    let providerDisplayName: String
    let accountLabel: String
    let storageScope: ProviderAccountStorageScope
    let quotaState: ProviderRoutingQuotaState
    let isActive: Bool
    let isNextFallback: Bool
    let lastUsedAt: Date?
    let cooldownUntil: Date?
}

/// Header that summarizes a routing pool — which endpoint serves it, which
/// providers are routable into it, how many accounts the user has wired up.
private struct PoolHeader: Hashable {
    let pool: RoutingPool
    let endpoint: String
    let routableProviderDisplayNames: [String]
    let accountCount: Int

    var explainerCopy: String {
        switch pool {
        case .openaiCompat:
            return "Cursor, Factory, Forge, OpenCode, and Codex CLI in API-key mode all send OpenAI-shape requests through this pool. Provider-Family mode stays inside the selected provider; Intelligent mode ranks compatible OpenAI-shape routes."
        case .anthropic:
            return "Claude Code (`ANTHROPIC_BASE_URL` mode) sends Anthropic-shape requests through this pool. Provider-Family mode stays inside Anthropic accounts; Intelligent mode ranks compatible Anthropic-shape routes."
        }
    }
}

private extension ProviderRouterMode {
    var displayName: String {
        switch self {
        case .providerFamilyFailover: return "Provider-Family Failover"
        case .intelligentModelRouter: return "Intelligent Model Router"
        }
    }

    var shortDescription: String {
        switch self {
        case .providerFamilyFailover:
            return "Extends capacity across accounts for the selected provider family only."
        case .intelligentModelRouter:
            return "Ranks compatible routes using task, account health, cost, latency, capability, and benchmark freshness signals."
        }
    }
}

/// Format-family pool — matches the daemon's `BurnBarProviderFormatFamily`
/// but lives in the SwiftUI module so we don't pull the daemon target into
/// AgentLens.
private enum RoutingPool: String, CaseIterable, Identifiable, Hashable {
    case openaiCompat
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openaiCompat: return "OpenAI-family"
        case .anthropic: return "Anthropic-family"
        }
    }

    var endpoint: String {
        switch self {
        case .openaiCompat: return "POST /v1/chat/completions"
        case .anthropic: return "POST /v1/messages"
        }
    }

    var wireTarget: RoutingClientWiringTarget {
        switch self {
        case .openaiCompat: return .codex
        case .anthropic: return .claudeCode
        }
    }

    var accentColor: Color {
        switch self {
        case .openaiCompat: return DesignSystem.Colors.ember
        case .anthropic: return DesignSystem.Colors.hermesMercury
        }
    }
}

// MARK: - View model

@MainActor
@Observable
private final class RoutingPoolsViewModel {

    var selectedPool: RoutingPool = .openaiCompat
    var snippetTarget: RoutingClientWiringTarget?
    var lastWireSummary: [RoutingClientWiringTarget: String] = [:]
    var lastWireError: [RoutingClientWiringTarget: String] = [:]
    var probeStatus: [RoutingClientWiringTarget: RoutingClientWiringProbe] = [:]
    var isProbing: [RoutingClientWiringTarget: Bool] = [:]
    var isWiringChanging: [RoutingClientWiringTarget: Bool] = [:]
    /// Most recent target whose snippet copy succeeded. Cleared after a
    /// short delay so the UI can show a one-shot "Copied!" confirmation.
    var copiedSnippetTarget: RoutingClientWiringTarget?

    private let wiringFactory: () -> RoutingClientWiring
    private let routedClientSyncFactory: () -> RoutedClientConfigSyncService
    private static let defaultOpenAIModels = [
        "glm-5-turbo",
        "minimax-m2.7-highspeed",
        "deepseek-v4-flash:cloud"
    ]

    init(
        wiringFactory: @escaping () -> RoutingClientWiring = { RoutingClientWiring() },
        routedClientSyncFactory: @escaping () -> RoutedClientConfigSyncService = { RoutedClientConfigSyncService() }
    ) {
        self.wiringFactory = wiringFactory
        self.routedClientSyncFactory = routedClientSyncFactory
    }

    func isWired(for target: RoutingClientWiringTarget) -> Bool {
        wiringFactory().isWired(target: target)
    }

    func gateway(from settings: SettingsManager) -> RoutingClientGateway {
        RoutingClientGateway(
            host: settings.gatewayHost,
            port: settings.gatewayPort,
            authToken: settings.gatewayAuthToken
        )
    }

    func wire(target: RoutingClientWiringTarget, gateway: RoutingClientGateway) async {
        isWiringChanging[target] = true
        defer { isWiringChanging[target] = false }
        do {
            let change = try wiringFactory().wire(target: target, gateway: gateway)
            let pathLine = "Updated \(change.configURL.path)"
            let backupLine = change.backupURL.map { " (backup: \($0.lastPathComponent))" } ?? ""
            lastWireSummary[target] = pathLine + backupLine
            lastWireError[target] = nil
        } catch {
            lastWireError[target] = error.localizedDescription
        }
    }

    func unwire(target: RoutingClientWiringTarget) async {
        isWiringChanging[target] = true
        defer { isWiringChanging[target] = false }
        do {
            try wiringFactory().unwire(target: target)
            lastWireSummary[target] = "Removed OpenBurnBar wiring."
            lastWireError[target] = nil
        } catch {
            lastWireError[target] = error.localizedDescription
        }
    }

    func probe(target: RoutingClientWiringTarget, gateway: RoutingClientGateway) async {
        isProbing[target] = true
        defer { isProbing[target] = false }
        let result = await wiringFactory().probe(target: target, gateway: gateway)
        probeStatus[target] = result
    }

    func snippet(for target: RoutingClientWiringTarget, gateway: RoutingClientGateway) -> String {
        wiringFactory().shellSnippet(target: target, gateway: gateway)
    }

    func isDroidSynced() -> Bool {
        routedClientSyncFactory().isFactoryGatewayConfigPresent()
    }

    func syncDroidFactoryConfig(gateway: RoutingClientGateway) async {
        isWiringChanging[.codex] = true
        defer { isWiringChanging[.codex] = false }
        do {
            let config = RoutedClientGatewayConfig(
                baseURL: "\(gateway.baseURL)/v1",
                bearerToken: gateway.authToken,
                models: Self.defaultOpenAIModels
            )
            let urls = try routedClientSyncFactory().applyFactoryGatewayConfig(config)
            let paths = urls.map(\.path).joined(separator: ", ")
            lastWireSummary[.codex] = "Synced Droid/Factory config: \(paths)"
            lastWireError[.codex] = nil
        } catch {
            lastWireError[.codex] = error.localizedDescription
        }
    }

    /// Copy a snippet to the system clipboard and surface a transient
    /// "Copied!" confirmation pinned to the target. The confirmation auto-
    /// clears after ~1.6s so it doesn't linger past the user's attention.
    func copySnippet(for target: RoutingClientWiringTarget, gateway: RoutingClientGateway) {
        let snippet = self.snippet(for: target, gateway: gateway)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet, forType: .string)
        copiedSnippetTarget = target
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self else { return }
            if self.copiedSnippetTarget == target {
                self.copiedSnippetTarget = nil
            }
        }
    }
}

// MARK: - View

/// Settings → Routing pools — the single surface for managing which routed
/// CLI clients ride the local gateway and which upstream accounts populate
/// each format-family pool.
struct RoutingPoolsView: View {
    let settingsManager: SettingsManager
    let dataStore: DataStore

    @State private var viewModel = RoutingPoolsViewModel()
    @State private var quotaService = ProviderQuotaService.shared
    @State private var daemonManager = OpenBurnBarDaemonManager.shared
    @State private var refreshTrigger = 0

    // Cached pool membership lookup. We resolve once on first render and
    // re-resolve only if the catalog reloads, which is rare in practice.
    private static let poolByProviderID: [ProviderID: RoutingPool] = {
        BurnBarCatalogLoader.bundledCatalog.providers.reduce(into: [:]) { result, provider in
            let providerID = ProviderID(rawValue: provider.id)
            switch provider.formatFamily {
            case .openaiCompat:
                result[providerID] = .openaiCompat
            case .anthropic:
                result[providerID] = .anthropic
            }
        }
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                explainerHeader
                setupChecklistCard
                routerModeCard
                poolPicker
                selectedPoolContent
            }
            .id(SettingsAnchor.routingPoolsOverview)
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignSystem.Colors.background)
        .navigationTitle("Routing pools")
        .task(id: refreshTrigger) {
            await refreshRoutingState()
        }
    }

    // MARK: - Explainer

    private var explainerHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text("Router setup")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            Text("This works like VibeProxy, but with OpenBurnBar's provider accounts and quota truth underneath: enable the local gateway, add at least two usable accounts in a pool, wire each CLI to the local endpoint, then let the daemon fail over when the active account is exhausted.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var setupChecklistCard: some View {
        let gateway = viewModel.gateway(from: settingsManager)
        let openAIRows = poolAccountRows(for: .openaiCompat)
        let anthropicRows = poolAccountRows(for: .anthropic)
        let hasFallbackReady = openAIRows.contains(where: \.isNextFallback)
            || anthropicRows.contains(where: \.isNextFallback)
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text("Setup checklist")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button {
                    useLocalGatewayDefaults()
                } label: {
                    Label("Use local defaults", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Enable the loopback gateway at 127.0.0.1:8317, matching VibeProxy's local-endpoint setup.")
            }

            setupStepRow(
                title: "Gateway",
                detail: settingsManager.gatewayEnabled
                    ? "\(gateway.baseURL) · \(gateway.isLoopbackHost && gateway.authToken.isEmpty ? "local auth off" : "bearer auth on")"
                    : "Off. Turn it on before probing routed clients.",
                isComplete: settingsManager.gatewayEnabled
            )
            setupStepRow(
                title: "OpenAI-family pool",
                detail: "\(openAIRows.count) account\(openAIRows.count == 1 ? "" : "s") for Codex, Droid/Factory, Forge, Cursor, and OpenCode.",
                isComplete: !openAIRows.isEmpty
            )
            setupStepRow(
                title: "Anthropic pool",
                detail: "\(anthropicRows.count) account\(anthropicRows.count == 1 ? "" : "s") for Claude Code.",
                isComplete: !anthropicRows.isEmpty
            )
            setupStepRow(
                title: "Failover runway",
                detail: hasFallbackReady
                    ? "A next fallback is ready in at least one pool."
                    : "Add or enable a second healthy account to prove account exhaustion failover.",
                isComplete: hasFallbackReady
            )
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private func setupStepRow(title: String, detail: String, isComplete: Bool) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isComplete ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var routerModeCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: daemonManager.routerMode == .intelligentModelRouter ? "brain.head.profile" : "rectangle.2.swap")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.blaze)
                VStack(alignment: .leading, spacing: 2) {
                    Text(daemonManager.routerMode.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(daemonManager.routerMode.shortDescription)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                Picker("Router mode", selection: Binding(
                    get: { daemonManager.routerMode },
                    set: { mode in
                        Task { @MainActor in
                            await daemonManager.setRouterMode(mode)
                            await refreshRoutingState()
                        }
                    }
                )) {
                    ForEach(ProviderRouterMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .disabled(daemonManager.isBusy)
            }

            if daemonManager.routerMode == .intelligentModelRouter {
                benchmarkStatusRow
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private var benchmarkStatusRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("Benchmark freshness: unavailable locally until the daily cloud model-landscape job publishes a fresh snapshot; routing falls back to catalog, account health, quota, cost, and latency signals.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var poolPicker: some View {
        Picker("Pool", selection: $viewModel.selectedPool) {
            ForEach(RoutingPool.allCases) { pool in
                Text(pool.displayName).tag(pool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Per-pool content

    @ViewBuilder
    private var selectedPoolContent: some View {
        let rows = poolAccountRows(for: viewModel.selectedPool)
        let header = PoolHeader(
            pool: viewModel.selectedPool,
            endpoint: viewModel.selectedPool.endpoint,
            routableProviderDisplayNames: routableProviderDisplayNames(for: viewModel.selectedPool),
            accountCount: rows.count
        )
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            poolHeaderCard(header: header)
            clientSetupCards(for: viewModel.selectedPool)
            accountsList(rows: rows, pool: viewModel.selectedPool)
        }
    }

    private func poolHeaderCard(header: PoolHeader) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(header.pool.accentColor)
                    .frame(width: 10, height: 10)
                Text(header.pool.displayName)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Text(header.endpoint)
                    .font(DesignSystem.Typography.caption.monospaced())
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Text(header.explainerCopy)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !header.routableProviderDisplayNames.isEmpty {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "rectangle.stack.fill")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .font(.system(size: 11, weight: .semibold))
                    Text("Routes into:")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(header.routableProviderDisplayNames.joined(separator: " · "))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    // MARK: - Client setup cards

    @ViewBuilder
    private func clientSetupCards(for pool: RoutingPool) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pool.accentColor)
                Text("Client apps")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
            }

            switch pool {
            case .openaiCompat:
                wiringCard(target: .codex)
                droidFactorySyncCard
                wiringCard(target: .forge)
            case .anthropic:
                wiringCard(target: .claudeCode)
            }
        }
    }

    private func wiringCard(target: RoutingClientWiringTarget) -> some View {
        let gateway = viewModel.gateway(from: settingsManager)
        let isWired = viewModel.isWired(for: target)
        let isChanging = viewModel.isWiringChanging[target] == true
        let isProbing = viewModel.isProbing[target] == true
        let probeStatus = viewModel.probeStatus[target]
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(target == .claudeCode ? DesignSystem.Colors.hermesMercury : DesignSystem.Colors.ember)
                Text("Wire \(target.displayName) through the Hydrant")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                wiredPill(isWired: isWired)
            }
            Text(wiringExplainer(for: target))
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            gatewayReadinessCallout(gateway: gateway)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Toggle(isOn: Binding(
                    get: { isWired },
                    set: { newValue in
                        Task { @MainActor in
                            if newValue {
                                await viewModel.wire(target: target, gateway: gateway)
                            } else {
                                await viewModel.unwire(target: target)
                            }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isWired ? "Wired (config-file mode)" : "Not wired")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(configPathLabel(for: target))
                            .font(DesignSystem.Typography.tiny.monospaced())
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: DesignSystem.Colors.blaze))
                .disabled(isChanging)
                Spacer()
                Button {
                    Task { @MainActor in
                        await viewModel.probe(target: target, gateway: gateway)
                    }
                } label: {
                    if isProbing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Probe", systemImage: "wave.3.right")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isProbing || !settingsManager.gatewayEnabled)

                Button {
                    viewModel.snippetTarget = target
                } label: {
                    Label("Copy shell snippet", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let probeStatus {
                probeStatusRow(probeStatus)
            }
            if let summary = viewModel.lastWireSummary[target] {
                statusLine(text: summary, isError: false)
            }
            if let error = viewModel.lastWireError[target] {
                statusLine(text: error, isError: true)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
        .sheet(item: snippetTargetBinding) { boxed in
            snippetSheet(target: boxed.target, gateway: viewModel.gateway(from: settingsManager))
        }
    }

    private var droidFactorySyncCard: some View {
        let gateway = viewModel.gateway(from: settingsManager)
        let isSynced = viewModel.isDroidSynced()
        let isChanging = viewModel.isWiringChanging[.codex] == true
        let isProbing = viewModel.isProbing[.codex] == true
        let probeStatus = viewModel.probeStatus[.codex]
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text("Sync Droid CLI (Factory)")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                wiredPill(isWired: isSynced)
            }
            Text("Writes VibeProxy-style Factory custom models into ~/.factory/settings.json and ~/.factory/config.json using provider \"openai\", base_url \(gateway.baseURL)/v1, and a local dummy key when gateway auth is off.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            gatewayReadinessCallout(gateway: gateway)

            HStack(spacing: DesignSystem.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isSynced ? "Synced" : "Not synced")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("~/.factory/settings.json + ~/.factory/config.json")
                        .font(DesignSystem.Typography.tiny.monospaced())
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer()
                Button {
                    Task { @MainActor in
                        await viewModel.syncDroidFactoryConfig(gateway: gateway)
                    }
                } label: {
                    if isChanging {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Sync config", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isChanging)

                Button {
                    Task { @MainActor in
                        await viewModel.probe(target: .codex, gateway: gateway)
                    }
                } label: {
                    if isProbing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Probe pool", systemImage: "wave.3.right")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isProbing || !settingsManager.gatewayEnabled)
            }

            if let probeStatus {
                probeStatusRow(probeStatus)
            }
            if let summary = viewModel.lastWireSummary[.codex] {
                statusLine(text: summary, isError: false)
            }
            if let error = viewModel.lastWireError[.codex] {
                statusLine(text: error, isError: true)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var snippetTargetBinding: Binding<SnippetTargetBox?> {
        Binding(
            get: { viewModel.snippetTarget.map { SnippetTargetBox(target: $0) } },
            set: { viewModel.snippetTarget = $0?.target }
        )
    }

    private struct SnippetTargetBox: Identifiable {
        let target: RoutingClientWiringTarget
        var id: String { target.id }
    }

    private func snippetSheet(target: RoutingClientWiringTarget, gateway: RoutingClientGateway) -> some View {
        let snippet = viewModel.snippet(for: target, gateway: gateway)
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("\(target.displayName) — shell snippet")
                    .font(DesignSystem.Typography.headline)
                Spacer()
                Button("Done") { viewModel.snippetTarget = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Paste these into `~/.zshrc`, `~/.bashrc`, or your shell of choice. Restart \(target.displayName) so it picks up the env vars.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            ScrollView {
                Text(snippet)
                    .font(DesignSystem.Typography.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
            }
            HStack {
                Button {
                    viewModel.copySnippet(for: target, gateway: gateway)
                } label: {
                    if viewModel.copiedSnippetTarget == target {
                        Label("Copied!", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Copy to clipboard", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.borderedProminent)
                .animation(.easeInOut(duration: 0.2), value: viewModel.copiedSnippetTarget)
                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 540, minHeight: 380)
    }

    @ViewBuilder
    private func gatewayReadinessCallout(gateway: RoutingClientGateway) -> some View {
        if !settingsManager.gatewayEnabled {
            gatewayCallout(
                title: "Local gateway is off.",
                detail: "Use local defaults, then restart the daemon if prompted. Client config can be prepared now, but probes need the gateway running.",
                icon: "powerplug.fill",
                tint: DesignSystem.Colors.amber
            )
        } else if gateway.authToken.isEmpty && !gateway.isLoopbackHost {
            gatewayCallout(
                title: "Non-loopback gateway needs bearer auth.",
                detail: "Add an auth token under Settings -> Daemon -> HTTP gateway before wiring remote clients.",
                icon: "lock.trianglebadge.exclamationmark.fill",
                tint: DesignSystem.Colors.error
            )
        } else if gateway.authToken.isEmpty {
            gatewayCallout(
                title: "Loopback auth is off.",
                detail: "This matches VibeProxy's local setup: clients get a dummy key and the daemon accepts local requests without bearer auth.",
                icon: "checkmark.shield.fill",
                tint: DesignSystem.Colors.success
            )
        }
    }

    private func gatewayCallout(title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }

    private func useLocalGatewayDefaults() {
        settingsManager.gatewayEnabled = true
        settingsManager.gatewayHost = "127.0.0.1"
        settingsManager.gatewayPort = 8317
    }

    private func wiredPill(isWired: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isWired ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 10, weight: .semibold))
            Text(isWired ? "Wired" : "Not wired")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(isWired ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            (isWired ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted).opacity(0.12)
        )
        .clipShape(Capsule())
    }

    private func probeStatusRow(_ status: RoutingClientWiringProbe) -> some View {
        switch status {
        case .skipped(let reason):
            return statusLine(text: "Probe skipped — \(reason)", isError: false)
        case .ok(let model):
            return statusLine(text: "Probe ok — gateway served `\(model)` for a 1-token request.", isError: false)
        case .failed(let httpStatus, let message):
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmedMessage.isEmpty ? "" : " — \(trimmedMessage)"
            return statusLine(text: "Probe failed (HTTP \(httpStatus))\(suffix)", isError: true)
        }
    }

    private func statusLine(text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isError ? DesignSystem.Colors.error : DesignSystem.Colors.success)
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(isError ? DesignSystem.Colors.error : DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func wiringExplainer(for target: RoutingClientWiringTarget) -> String {
        switch target {
        case .claudeCode:
            return "Writes ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN into ~/.claude/settings.json (and snapshots the previous file). Claude Code now sends every request through the local gateway, which fails over across your Anthropic accounts in the same pool."
        case .codex:
            return "Drops a sentinel-fenced [model_providers.openburnbar] block plus a [profiles.openburnbar] profile into ~/.codex/config.toml. Run `codex --profile openburnbar` after exporting OPENBURNBAR_GATEWAY_TOKEN from the snippet sheet. Codex's ChatGPT-auth mode is not routed; only the API-key path is."
        case .forge:
            return "Adds a VibeProxy-style [[providers]] entry named openburnbar to ~/forge/.forge.toml with a chat-completions URL, models URL, and OPENBURNBAR_GATEWAY_TOKEN env var. Your existing Forge session provider is left alone so you can opt in deliberately."
        }
    }

    private func configPathLabel(for target: RoutingClientWiringTarget) -> String {
        switch target {
        case .claudeCode: return "~/.claude/settings.json"
        case .codex: return "~/.codex/config.toml"
        case .forge: return "~/forge/.forge.toml"
        }
    }

    // MARK: - Account list per pool

    @ViewBuilder
    private func accountsList(rows: [PoolAccountRow], pool: RoutingPool) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Routed accounts")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button {
                    refreshTrigger &+= 1
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if rows.isEmpty {
                emptyAccountsRow(for: pool)
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    ForEach(rows) { row in
                        accountRowView(row)
                    }
                }
            }
        }
    }

    private func emptyAccountsRow(for pool: RoutingPool) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(pool == .anthropic
                ? "No Anthropic accounts yet. Add an Anthropic Console API key or sign in with an Anthropic Pro/Team plan to make this pool useful."
                : "No OpenAI-family accounts yet. Add an OpenAI, Z.ai, MiniMax, Kimi, or Ollama key in Providers → Add account."
            )
            .font(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.5))
        )
    }

    private func accountRowView(_ row: PoolAccountRow) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            quotaStateDot(row.quotaState)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.accountLabel)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isActive {
                        rolePill("active", tint: DesignSystem.Colors.success)
                    } else if row.isNextFallback {
                        rolePill("next-fallback", tint: DesignSystem.Colors.amber)
                    }
                }
                HStack(spacing: 6) {
                    Text(row.providerDisplayName)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("·")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(ProviderRoutingStateText.label(row.quotaState))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    if let cooldown = row.cooldownUntil, cooldown > Date() {
                        Text("·")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text("Resumes \(cooldown.formatted(.relative(presentation: .named)))")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Image(systemName: ProviderAccountStorage.iconName(row.storageScope))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ProviderAccountStorage.tint(row.storageScope))
                        .help(ProviderAccountStorage.description(row.storageScope))
                }
            }
            Spacer()
            if let lastUsed = row.lastUsedAt {
                Text(lastUsed.formatted(.relative(presentation: .named)))
                    .font(DesignSystem.Typography.tiny.monospaced())
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(row.isActive
                    ? DesignSystem.Colors.success.opacity(0.06)
                    : DesignSystem.Colors.surface.opacity(0.5)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(row.isActive
                    ? DesignSystem.Colors.success.opacity(0.5)
                    : DesignSystem.Colors.border.opacity(0.3),
                    lineWidth: 0.5
                )
        )
    }

    private func quotaStateDot(_ state: ProviderRoutingQuotaState) -> some View {
        Circle()
            .fill(ProviderRoutingVisual.tint(state))
            .frame(width: 8, height: 8)
    }

    private func rolePill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Data assembly

    private func poolAccountRows(for pool: RoutingPool) -> [PoolAccountRow] {
        let accounts: [ProviderAccountDoc] = (try? dataStore.providerAccountStore.fetchAll()) ?? []
        let scopedAccounts = accounts.filter { Self.pool(for: $0.providerID) == pool }
        let routingByProvider = quotaService.routingStatesByProviderID

        var rows: [PoolAccountRow] = []
        let grouped = Dictionary(grouping: scopedAccounts, by: { $0.providerID })
        let orderedProviders = grouped.keys.sorted { lhs, rhs in
            providerDisplayName(for: lhs).localizedCaseInsensitiveCompare(providerDisplayName(for: rhs)) == .orderedAscending
        }

        for providerID in orderedProviders {
            let providerAccounts = grouped[providerID] ?? []
            let snapshot = routingByProvider[providerID]
            let activeID = snapshot?.activeAccount?.accountID
            let fallbackID = snapshot?.nextFallback?.accountID
            let blocked = snapshot?.exhaustedOrCoolingDownAccounts ?? []
            let blockedByID = Dictionary(uniqueKeysWithValues: blocked.map { ($0.accountID, $0) })

            let ordered = providerAccounts.sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }

            for account in ordered {
                let state: ProviderRoutingQuotaState = {
                    if account.id == activeID, let candidate = snapshot?.activeAccount {
                        return candidate.quotaState
                    }
                    if let candidate = blockedByID[account.id] {
                        return candidate.quotaState
                    }
                    if account.id == fallbackID, let candidate = snapshot?.nextFallback {
                        return candidate.quotaState
                    }
                    return quotaState(
                        for: account,
                        snapshot: quotaService.snapshotsByAccountID[account.id]
                    )
                }()
                let cooldown: Date? = {
                    if account.id == activeID { return snapshot?.activeAccount?.cooldownUntil }
                    if account.id == fallbackID { return snapshot?.nextFallback?.cooldownUntil }
                    return blockedByID[account.id]?.cooldownUntil
                }()
                rows.append(
                    PoolAccountRow(
                        id: account.id,
                        providerID: account.providerID,
                        providerDisplayName: providerDisplayName(for: account.providerID),
                        accountLabel: account.label,
                        storageScope: account.storageScope,
                        quotaState: state,
                        isActive: account.id == activeID,
                        isNextFallback: account.id == fallbackID,
                        lastUsedAt: account.lastRefreshAt,
                        cooldownUntil: cooldown
                    )
                )
            }
        }
        return rows
    }

    private func quotaState(
        for account: ProviderAccountDoc,
        snapshot: ProviderQuotaSnapshot?
    ) -> ProviderRoutingQuotaState {
        switch account.status {
        case .deleted:
            return .deleted
        case .disabled:
            return .disabled
        case .error, .disconnected:
            return .authFailed
        case .stale, .connected:
            break
        }

        guard let snapshot else {
            return account.status == .stale ? .pressure : .unknown
        }

        let remainingFractions = snapshot.displayableQuotaBuckets.compactMap { bucket -> Double? in
            guard let remainingPercent = bucket.remainingPercent else { return nil }
            return max(0, remainingPercent) / 100
        }

        guard let remaining = remainingFractions.min() else {
            return snapshot.confidence == .unavailable ? .pressure : .unknown
        }

        if remaining <= 0 { return .exhausted }
        if remaining <= 0.20 { return .pressure }
        return snapshot.confidence == .unavailable ? .pressure : .healthy
    }

    private func providerDisplayName(for providerID: ProviderID) -> String {
        if let configuration = daemonManager.providerConfigurations.first(where: { $0.providerID == providerID.rawValue }) {
            return configuration.displayName
        }
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID.rawValue) {
            return catalogProvider.displayName
        }
        return providerID.rawValue
    }

    private func routableProviderDisplayNames(for pool: RoutingPool) -> [String] {
        BurnBarCatalogLoader.bundledCatalog.providers
            .filter { Self.pool(for: ProviderID(rawValue: $0.id)) == pool }
            .map(\.displayName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func pool(for providerID: ProviderID) -> RoutingPool {
        if let resolved = poolByProviderID[providerID] {
            return resolved
        }
        // Unknown providers default to OpenAI-family — Anthropic membership is
        // explicit in the bundled catalog.
        return .openaiCompat
    }

    // MARK: - State refresh

    private func refreshRoutingState() async {
        _ = quotaService.refreshRoutingState(
            dataStore: dataStore,
            request: ProviderRoutingRequest(
                routerMode: daemonManager.routerMode,
                taskCategory: .coding,
                benchmarkStatus: daemonManager.routerMode == .intelligentModelRouter
                    ? ProviderModelBenchmarkStatus(
                        source: .cachedFixture,
                        freshness: .unavailable,
                        message: "No local benchmark snapshot is available yet.",
                        attribution: "OpenBurnBar model landscape adapters"
                    )
                    : nil
            )
        )
    }
}
