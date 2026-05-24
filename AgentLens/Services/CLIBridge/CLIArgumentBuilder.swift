import Foundation
import OpenBurnBarComputerUseCore

enum CodexModelCatalog {
    static let chatModelIDs: [String] = [
        "gpt-5.5",
        "gpt-5.5-mini",
        "gpt-5.5-nano",
        "gpt-5.5-pro",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.4-pro",
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        "gpt-5.2-pro",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max"
    ]

    private static let slugAliases: [String: String] = [
        "gpt-5-5": "gpt-5.5",
        "gpt-5-5-mini": "gpt-5.5-mini",
        "gpt-5-5-nano": "gpt-5.5-nano",
        "gpt-5-5-pro": "gpt-5.5-pro",
        "gpt-5-4": "gpt-5.4",
        "gpt-5-4-mini": "gpt-5.4-mini",
        "gpt-5-4-nano": "gpt-5.4-nano",
        "gpt-5-4-pro": "gpt-5.4-pro",
        "gpt-5-3-codex": "gpt-5.3-codex",
        "gpt-5-2-codex": "gpt-5.2-codex",
        "gpt-5-2-pro": "gpt-5.2-pro",
        "gpt-5-1-codex": "gpt-5.1-codex",
        "gpt-5-1-codex-mini": "gpt-5.1-codex-mini",
        "gpt-5-1-codex-max": "gpt-5.1-codex-max"
    ]

    static func normalizedModel(_ model: String, fallback: String = "") -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedModel.isEmpty == false else { return fallback }

        if let canonical = slugAliases[trimmedModel.lowercased()] {
            return canonical
        }

        if let canonical = chatModelIDs.first(where: {
            $0.caseInsensitiveCompare(trimmedModel) == .orderedSame
        }) {
            return canonical
        }

        return trimmedModel
    }
}

enum CLIArgumentBuilder {
    static func sanitizedPrompt(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\u{0001}", with: "")
            .replacingOccurrences(of: "\u{0002}", with: "")
            .replacingOccurrences(of: "\u{0003}", with: "")
            .replacingOccurrences(of: "\u{0004}", with: "")
            .replacingOccurrences(of: "\u{0005}", with: "")
            .replacingOccurrences(of: "\u{0006}", with: "")
            .replacingOccurrences(of: "\u{0007}", with: "")
            .replacingOccurrences(of: "\u{0008}", with: "")
            .replacingOccurrences(of: "\u{000B}", with: "")
            .replacingOccurrences(of: "\u{000C}", with: "")
    }

    static func claudeArguments(
        prompt: String,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> [String] {
        var arguments = [
            "-p",
            sanitizedPrompt(prompt),
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel.isEmpty == false {
            arguments.append(contentsOf: ["--model", trimmedModel])
        }
        arguments.append(contentsOf: [
            "--output-format",
            "stream-json",
            "--verbose",
        ])
        if let capabilityGrant, capabilityGrant.isActive() {
            let allowed = claudeAllowedTools(for: capabilityGrant)
            if !allowed.isEmpty {
                arguments.append(contentsOf: ["--allowedTools", allowed.joined(separator: ",")])
            }
            if isYOLOGrant(capabilityGrant) {
                arguments.append("--dangerously-skip-permissions")
            } else if capabilityGrant.capabilities.contains(.workspaceWrite) {
                arguments.append(contentsOf: ["--permission-mode", "acceptEdits"])
            }
        }
        return arguments
    }

    static func codexArguments(
        prompt: String,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> [String] {
        var arguments = [
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "-c",
            #"model_reasoning_effort="high""#,
            sanitizedPrompt(prompt)
        ]
        let normalizedModel = CodexModelCatalog.normalizedModel(model)
        if !normalizedModel.isEmpty {
            arguments.insert(contentsOf: ["-m", normalizedModel], at: 4)
        }
        if let capabilityGrant, capabilityGrant.isActive() {
            if isYOLOGrant(capabilityGrant) {
                arguments.insert("--dangerously-bypass-approvals-and-sandbox", at: arguments.count - 1)
            } else if capabilityGrant.capabilities.contains(.workspaceWrite) ||
                capabilityGrant.capabilities.contains(.shell) {
                arguments.insert(contentsOf: ["--sandbox", "workspace-write"], at: arguments.count - 1)
            } else if capabilityGrant.capabilities.contains(.workspaceRead) {
                arguments.insert(contentsOf: ["--sandbox", "read-only"], at: arguments.count - 1)
            }
        }
        return arguments
    }

    private static func claudeAllowedTools(for grant: AgentCapabilityGrant) -> [String] {
        var tools: [String] = []
        if grant.capabilities.contains(.workspaceRead) {
            tools.append(contentsOf: ["Read", "Glob", "Grep", "LS"])
        }
        if grant.capabilities.contains(.workspaceWrite) {
            tools.append(contentsOf: ["Write", "Edit", "MultiEdit"])
        }
        if grant.capabilities.contains(.shell) {
            tools.append("Bash")
        }
        return Array(NSOrderedSet(array: tools)) as? [String] ?? tools
    }

    private static func isYOLOGrant(_ grant: AgentCapabilityGrant) -> Bool {
        grant.trustMode == .trusted && Set(AgentDesktopCapability.allCases).isSubset(of: grant.capabilities)
    }

    static func combinedPrompt(systemPrompt: String, userMessage: String) -> String {
        """
        \(systemPrompt)

        User:
        \(userMessage)
        """
    }
}

extension CLIBridge {
    nonisolated static func sanitizedPrompt(_ input: String) -> String {
        CLIArgumentBuilder.sanitizedPrompt(input)
    }

    nonisolated static func claudeArguments(
        prompt: String,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> [String] {
        CLIArgumentBuilder.claudeArguments(prompt: prompt, model: model, capabilityGrant: capabilityGrant)
    }

    nonisolated static var codexChatModelIDs: [String] {
        CodexModelCatalog.chatModelIDs
    }

    nonisolated static func normalizedCodexModel(_ model: String, fallback: String = "") -> String {
        CodexModelCatalog.normalizedModel(model, fallback: fallback)
    }

    nonisolated static func codexArguments(
        prompt: String,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> [String] {
        CLIArgumentBuilder.codexArguments(prompt: prompt, model: model, capabilityGrant: capabilityGrant)
    }
}
