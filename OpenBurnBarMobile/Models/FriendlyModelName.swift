import Foundation

// MARK: - Friendly Model Name

/// Turns wire model IDs ("grok-build-0.1", "gpt-5.5-codex", "minimax-m2.7")
/// into copy a person can read ("Grok Build 0.1", "GPT-5.5 Codex",
/// "MiniMax M2.7"). Pure and deterministic so every surface — the chat title,
/// the "via Hermes" badge, the model pickers — renders the same name.
///
/// Inputs that already contain whitespace are treated as human-authored
/// display names and returned untouched.
enum FriendlyModelName {
    /// Lowercased token → exact rendering. Tokens not listed here fall back
    /// to pattern rules (size suffixes, letter+version) and then plain
    /// capitalization.
    private static let tokenMap: [String: String] = [
        // Initialisms
        "gpt": "GPT", "glm": "GLM", "llm": "LLM", "oss": "OSS", "moe": "MoE",
        "vl": "VL", "ai": "AI", "xl": "XL", "it": "IT", "sft": "SFT",
        "dpo": "DPO", "fp8": "FP8", "fp16": "FP16", "awq": "AWQ",
        "gguf": "GGUF", "mlx": "MLX", "hf": "HF", "qwq": "QwQ",
        // Brand casings that plain capitalization gets wrong
        "minimax": "MiniMax", "deepseek": "DeepSeek", "openai": "OpenAI",
        "xai": "xAI", "chatgpt": "ChatGPT", "tinyllama": "TinyLlama",
        "openhermes": "OpenHermes", "dbrx": "DBRX", "wizardlm": "WizardLM",
        "openchat": "OpenChat", "smollm": "SmolLM", "internlm": "InternLM",
        "minicpm": "MiniCPM",
        // OpenAI's o-series is styled lowercase ("o3 Mini")
        "o1": "o1", "o3": "o3", "o4": "o4"
    ]

    /// Initialisms that hyphen-join a directly following version token, so
    /// "gpt-5.5-codex" reads "GPT-5.5 Codex" rather than "GPT 5.5 Codex".
    private static let hyphenJoiningAcronyms: Set<String> = ["GPT", "GLM", "o1", "o3", "o4"]

    static func format(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        // Contains whitespace → already a human display name.
        guard trimmed.rangeOfCharacter(from: .whitespaces) == nil else { return trimmed }

        // Drop provider/org path prefixes: "openrouter/x-ai/grok-4" → "grok-4".
        let base = trimmed.split(separator: "/").last.map(String.init) ?? trimmed

        // ":" separates Ollama-style tags ("llama3:8b") — treat as a word break.
        let rawTokens = base
            .replacingOccurrences(of: ":", with: "-")
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)

        // Drop trailing date stamps ("…-20251001", "…-2025-10-01").
        var tokens = rawTokens
        while let last = tokens.last, tokens.count > 1, isDateStamp(last) {
            tokens.removeLast()
        }
        guard !tokens.isEmpty else { return trimmed }

        let rendered = tokens.map(renderToken)

        // Join, hyphenating "GPT" + "5.5"-style pairs.
        var result = ""
        for (index, token) in rendered.enumerated() {
            if index == 0 {
                result = token
            } else if hyphenJoiningAcronyms.contains(rendered[index - 1]),
                      token.first?.isNumber == true {
                result += "-" + token
            } else {
                result += " " + token
            }
        }
        return result.isEmpty ? trimmed : result
    }

    // MARK: - Token rules

    private static func renderToken(_ token: String) -> String {
        let lower = token.lowercased()
        if let mapped = tokenMap[lower] { return mapped }

        // Pure number / version: "5.5", "0.1", "405" — keep as-is.
        if token.first?.isNumber == true {
            // Size suffixes: "70b" → "70B", "235m" → "235M", "8x7b" → "8x7B".
            if let last = lower.last, "bmk".contains(last),
               lower.dropLast().allSatisfy({ $0.isNumber || $0 == "." || $0 == "x" }) {
                return lower.dropLast().appending(String(last).uppercased())
            }
            return token
        }

        // Letter + version: "m2.7" → "M2.7", "v3.1" → "V3.1", "k2" → "K2".
        if lower.count >= 2,
           let first = lower.first, first.isLetter,
           lower.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }

        // Compact spec tokens like "a3b" → "A3B".
        if lower.count <= 4,
           lower.contains(where: { $0.isNumber }),
           lower.contains(where: { $0.isLetter }),
           lower.allSatisfy({ $0.isNumber || $0.isLetter }) {
            return lower.uppercased()
        }

        // Default: capitalize first letter, keep the rest.
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    private static func isDateStamp(_ token: String) -> Bool {
        (token.count == 8 || token.count == 6) && token.allSatisfy(\.isNumber)
    }
}
