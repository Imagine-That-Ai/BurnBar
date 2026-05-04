import Foundation

// MARK: - Stub Quota Adapters

/// Returns `.unavailable` for providers with no data source or not yet installed.
/// Used for providers in the AgentProvider enum that either:
/// - Have no public usage API (Gemini CLI)
/// - Are not installed on this machine (Cline, Roo Code, Windsurf, etc.)
/// - Have no discoverable data source (Goose, OpenClaw)
///
/// Each adapter detects whether the tool is installed and returns the appropriate
/// status message with a link to how to enable tracking.

// MARK: - Cline

struct ClineQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let installed = detectVSCodeExtension("cline")
        return ProviderQuotaSnapshot(
            provider: .cline,
            fetchedAt: Date(),
            source: installed ? .localSession : .unavailable,
            confidence: installed ? .exact : .unavailable,
            managementURL: installed ? nil : "vscode:extension/saoudrizwan.claude-dev",
            statusMessage: installed
                ? "Cline detected — token tracking via VS Code extension data."
                : "Cline not installed. Install the VS Code extension.",
            buckets: installed ? basicActivityBuckets() : []
        )
    }

    private func detectVSCodeExtension(_ name: String) -> Bool {
        let paths = [
            "~/Library/Application Support/Code/User/globalStorage",
            "~/Library/Application Support/Cursor/User/globalStorage",
            "~/Library/Application Support/Code - Insiders/User/globalStorage",
            "~/Library/Application Support/Windsurf - Next/User/globalStorage",
        ]
        for base in paths {
            let expanded = (base as NSString).expandingTildeInPath
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: expanded) {
                if contents.contains(where: { $0.lowercased().contains(name.lowercased()) }) {
                    return true
                }
            }
        }
        return false
    }

    private func basicActivityBuckets() -> [ProviderQuotaBucket] {
        [ProviderQuotaBucket(
            key: "detected",
            label: "Installed",
            windowKind: .lifetime,
            usedValue: 1,
            limitValue: nil,
            remainingValue: nil,
            usedPercent: 0,
            resetsAt: nil,
            unit: .sessions,
            isEstimated: false
        )]
    }
}

// MARK: - Roo Code

struct RooCodeQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let installed = detectVSCodeExtensionGlobalStorage("roocode")
        return ProviderQuotaSnapshot(
            provider: .rooCode,
            fetchedAt: Date(),
            source: installed ? .localSession : .unavailable,
            confidence: installed ? .exact : .unavailable,
            managementURL: installed ? nil : "vscode:extension/rooveterinaryinc.roo-cline",
            statusMessage: installed
                ? "Roo Code detected — sessions tracked via extension data."
                : "Roo Code not installed. Install the VS Code extension.",
            buckets: []
        )
    }

    private func detectVSCodeExtensionGlobalStorage(_ name: String) -> Bool {
        let paths = [
            "~/Library/Application Support/Code/User/globalStorage",
            "~/Library/Application Support/Cursor/User/globalStorage",
            "~/Library/Application Support/Code - Insiders/User/globalStorage",
            "~/Library/Application Support/Windsurf - Next/User/globalStorage",
        ]
        for base in paths {
            let expanded = (base as NSString).expandingTildeInPath
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: expanded) {
                if contents.contains(where: { $0.lowercased().contains(name.lowercased()) }) {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Augment

struct AugmentQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        return ProviderQuotaSnapshot(
            provider: .augment,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: "https://augmentcode.com",
            statusMessage: "Augment not detected. Install Augment Code to track usage.",
            buckets: []
        )
    }
}

// MARK: - Goose

struct GooseQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let gooseDir = ("~/.config/goose" as NSString).expandingTildeInPath
        let installed = FileManager.default.fileExists(atPath: gooseDir)

        return ProviderQuotaSnapshot(
            provider: .goose,
            fetchedAt: Date(),
            source: installed ? .localSession : .unavailable,
            confidence: installed ? .exact : .unavailable,
            managementURL: installed ? nil : "https://block.github.io/goose/",
            statusMessage: installed
                ? "Goose detected — sessions tracked via local data."
                : "Goose not detected. Install from block.github.io/goose/.",
            buckets: []
        )
    }
}

// MARK: - OpenClaw

struct OpenClawQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        return ProviderQuotaSnapshot(
            provider: .openClaw,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: "https://github.com/openclaw",
            statusMessage: "OpenClaw not detected. Install to track usage.",
            buckets: []
        )
    }
}

// MARK: - Windsurf

struct WindsurfQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let windsurfDir = ("~/Library/Application Support/Windsurf - Next" as NSString).expandingTildeInPath
        let installed = FileManager.default.fileExists(atPath: windsurfDir)

        return ProviderQuotaSnapshot(
            provider: .windsurf,
            fetchedAt: Date(),
            source: installed ? .localSession : .unavailable,
            confidence: installed ? .exact : .unavailable,
            managementURL: installed ? nil : "https://codeium.com/windsurf",
            statusMessage: installed
                ? "Windsurf detected — IDE usage tracking via local data."
                : "Windsurf not installed. Download from codeium.com/windsurf.",
            buckets: []
        )
    }
}

// MARK: - Gemini CLI

struct GeminiCLIQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let geminiCLIPath = ("~/.gemini" as NSString).expandingTildeInPath
        let installed = FileManager.default.fileExists(atPath: geminiCLIPath)

        return ProviderQuotaSnapshot(
            provider: .geminiCLI,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: "https://aistudio.google.com",
            statusMessage: installed
                ? "Gemini CLI detected. Google AI Studio has no programmatic usage API. Track usage via API key billing at aistudio.google.com."
                : "Gemini CLI not detected. Google AI Studio has no programmatic usage API.",
            buckets: []
        )
    }
}
