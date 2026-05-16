import Foundation

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

    static func normalizedModel(_ model: String, fallback: String = "gpt-5.5") -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedModel.isEmpty == false else { return fallback }

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

    static func claudeArguments(prompt: String, model: String = "") -> [String] {
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
        return arguments
    }

    static func codexArguments(prompt: String, model: String = "gpt-5.5") -> [String] {
        [
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "-m",
            CodexModelCatalog.normalizedModel(model),
            "-c",
            #"model_reasoning_effort="high""#,
            sanitizedPrompt(prompt)
        ]
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

    nonisolated static func claudeArguments(prompt: String, model: String = "") -> [String] {
        CLIArgumentBuilder.claudeArguments(prompt: prompt, model: model)
    }

    nonisolated static var codexChatModelIDs: [String] {
        CodexModelCatalog.chatModelIDs
    }

    nonisolated static func normalizedCodexModel(_ model: String, fallback: String = "gpt-5.5") -> String {
        CodexModelCatalog.normalizedModel(model, fallback: fallback)
    }

    nonisolated static func codexArguments(prompt: String, model: String = "gpt-5.5") -> [String] {
        CLIArgumentBuilder.codexArguments(prompt: prompt, model: model)
    }
}
