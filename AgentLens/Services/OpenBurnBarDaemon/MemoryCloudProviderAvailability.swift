import Foundation
import OpenBurnBarKernel

// MARK: - Memory Pro: which provider rows can be turned on right now

/// A provider row is available when this Mac can actually use it: CLI rows need
/// the binary plus the "Mac CLI agents" consent; API rows need an enabled
/// credential slot in the daemon. The reason is shown under a disabled row.
@MainActor
enum MemoryCloudProviderAvailability {
    struct Snapshot: Equatable, Sendable {
        var unavailableReasons: [MemoryCloudProviderID: String] = [:]

        func reason(for id: MemoryCloudProviderID) -> String? { unavailableReasons[id] }
        func isAvailable(_ id: MemoryCloudProviderID) -> Bool { unavailableReasons[id] == nil }
    }

    static func cliExecutableName(for id: MemoryCloudProviderID) -> String? {
        switch id {
        case .claudeCLI: "claude"
        case .codexCLI: "codex"
        case .openrouter, .vercelAIGateway, .anthropic, .openai: nil
        }
    }

    /// Pure: decide every row from what is known.
    static func snapshot(
        cliAssistantAllowed: Bool,
        installedCLIs: Set<String>,
        daemonSnapshot: BurnBarProviderConfigurationSnapshot?
    ) -> Snapshot {
        var reasons: [MemoryCloudProviderID: String] = [:]
        for id in MemoryCloudProviderID.allCases {
            if let executable = cliExecutableName(for: id) {
                if !cliAssistantAllowed {
                    reasons[id] = "Allow Mac CLI agents in Settings → Privacy first."
                } else if !installedCLIs.contains(executable) {
                    reasons[id] = "Install the `\(executable)` CLI to use your subscription."
                }
                continue
            }
            guard let providerID = id.daemonProviderID else { continue }
            let slots = daemonSnapshot?.providers.first(where: { $0.providerID == providerID })?.credentialSlots ?? []
            if !slots.contains(where: \.isEnabled) {
                reasons[id] = "Add a \(id.displayName) key under Settings → Providers first."
            }
        }
        return Snapshot(unavailableReasons: reasons)
    }

    /// Live: resolve the CLIs and read the daemon snapshot off the main actor.
    static func current(
        settingsManager: SettingsManager,
        daemonManager: OpenBurnBarDaemonManager,
        resolver: CLIExecutableResolver = CLIExecutableResolver()
    ) async -> Snapshot {
        var installed: Set<String> = []
        let claude = await resolver.resolveExecutable(named: "claude")
        let codex = await resolver.resolveExecutable(named: "codex")
        if claude != nil { installed.insert("claude") }
        if codex != nil { installed.insert("codex") }
        let dependencies = daemonManager.dependencies
        let socketURL = daemonManager.paths.socketURL
        var daemonSnapshot: BurnBarProviderConfigurationSnapshot?
        do {
            daemonSnapshot = try await daemonManager.daemonRPC {
                try dependencies.requestConfig(socketURL)
            }
        } catch {
            daemonSnapshot = nil  // daemon down: API rows show "add a key" until it is back
        }
        return snapshot(
            cliAssistantAllowed: settingsManager.cliAssistantAllowed,
            installedCLIs: installed,
            daemonSnapshot: daemonSnapshot
        )
    }
}
