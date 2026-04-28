import Foundation

// MARK: - Provider Path Settings

@Observable
@MainActor
final class ProviderPathSettings {
    private let persistence: SettingsPersistenceCoordinator

    var logPaths: [AgentProvider: String] = [:] {
        didSet {
            for (provider, path) in logPaths {
                persistence.set(path, forKey: "logPath_\(provider.rawValue)")
            }
        }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        var loadedLogPaths: [AgentProvider: String] = [:]
        for provider in AgentProvider.allCases {
            let customPath = persistence.optionalString(forKey: "logPath_\(provider.rawValue)")
            loadedLogPaths[provider] = customPath ?? provider.logDirectory
        }
        self.logPaths = loadedLogPaths
    }

    func resetPathsToDefaults() {
        logPaths = AgentProvider.allCases.reduce(into: [:]) { result, provider in
            result[provider] = provider.logDirectory
        }
    }

    func detectAvailableProviders() -> [AgentProvider: Bool] {
        var result: [AgentProvider: Bool] = [:]
        for provider in AgentProvider.allCases {
            result[provider] = candidatePaths(for: provider, configuredPath: provider.logDirectory).contains {
                FileManager.default.fileExists(atPath: $0)
            }
        }
        return result
    }

    func pathExists(for provider: AgentProvider, restrictedLogAccess: Bool) -> Bool {
        let path = restrictedLogDirectory(for: provider, restrictedLogAccess: restrictedLogAccess)
        return candidatePaths(for: provider, configuredPath: path).contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    func restrictedLogDirectory(for provider: AgentProvider, restrictedLogAccess: Bool) -> String {
        let validator = RestrictedLogPathValidator(restrictedMode: restrictedLogAccess)
        let customPath = logPaths[provider]
        let defaultPath = provider.logDirectory
        return validator.resolvePath(customPath: customPath, providerDefault: defaultPath) ?? defaultPath
    }

    func resolvedPath(for provider: AgentProvider, restrictedLogAccess: Bool) -> URL? {
        let path = restrictedLogDirectory(for: provider, restrictedLogAccess: restrictedLogAccess)
        let expandedPaths = candidatePaths(for: provider, configuredPath: path)
        if let existing = expandedPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: existing)
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private func candidatePaths(for provider: AgentProvider, configuredPath: String) -> [String] {
        let expandedConfigured = (configuredPath as NSString).expandingTildeInPath
        var candidates: [String] = []

        switch provider {
        case .augment:
            candidates = [
                expandedConfigured,
                ("~/Library/Application Support/Code/User/globalStorage/augment.vscode-augment" as NSString).expandingTildeInPath,
                ("~/Library/Application Support/Cursor/User/globalStorage/augment.vscode-augment" as NSString).expandingTildeInPath,
                ("~/Library/Application Support/Windsurf/User/globalStorage/augment.vscode-augment" as NSString).expandingTildeInPath,
            ]
        case .hermes:
            candidates = [
                expandedConfigured,
                ("~/.hermes" as NSString).expandingTildeInPath,
                ("~/.hermes/sessions" as NSString).expandingTildeInPath,
            ]
        case .goose:
            if let root = ProcessInfo.processInfo.environment["GOOSE_PATH_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !root.isEmpty {
                candidates.append(((root as NSString).appendingPathComponent("data/sessions") as NSString).expandingTildeInPath)
            }
            candidates.append(contentsOf: [
                ("~/Library/Application Support/Block/goose/sessions" as NSString).expandingTildeInPath,
                ("~/.local/share/goose/sessions" as NSString).expandingTildeInPath,
                expandedConfigured,
            ])
        case .forgeDev:
            candidates = [
                expandedConfigured,
                ("~/.forge" as NSString).expandingTildeInPath,
            ]
        default:
            candidates = [expandedConfigured]
        }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }
}
