import Foundation

// MARK: - Factory Session Classifier

/// Classifies a `~/.factory/sessions/**/*.settings.json` payload by which
/// Factory billing lane (if any) it consumed.
///
/// ## Why this exists
///
/// Factory's CLI lets you point sessions at:
/// - **Factory's native lanes** (`providerLock=factory`) — these count
///   against Standard Usage / Droid Core / Extra Usage.
/// - **User-configured custom proxies** (`providerLock` ∈ {`openai`,
///   `anthropic`, `generic-chat-completion-api`, …}) — these route through
///   `config.json.custom_models[]` base_urls (third-party proxies, OpenCode-Go,
///   localhost Ollama, etc.) and are **not** billed by Factory at all.
///
/// Before this classifier, the adapter summed every session into the
/// Factory monthly cap, so on a power-user machine 1488 / 1514 sessions
/// were counted against Factory's plan even though they hit
/// user-controlled inference endpoints. The popover would routinely show
/// "100% of plan" inside a week of fresh installs. This file is the
/// single source of truth for "which sessions actually consumed Factory's
/// rate limits, and against which lane".
///
/// ## Lane assignment
///
/// Sessions with `providerLock == "factory"` are sub-classified:
///
/// - **Droid Core** — open-weight models Factory has designated as Core
///   (kimi, glm, deepseek, minimax variants). When Standard Usage is
///   exhausted, these draw from Droid Core's separate free pool. Until
///   Standard Usage is exhausted, they count against Standard.
/// - **Standard / Premium** — frontier closed-weight models (claude,
///   gpt, gemini families). These always consume Standard Usage and
///   never fall back to Droid Core.
///
/// Source: https://docs.factory.ai/pricing — "Droid Core is a set of
/// leading open-weight models that Factory has designated as Core."
/// Factory updates the Core list in `Settings → Models`; we approximate
/// the published list with model-family prefix matching so a new Core
/// model lands in the right bucket without an OpenBurnBar update.

enum FactorySessionLane: String, Sendable, Codable {
    /// Custom proxy / BYOK route — does NOT touch Factory's billing.
    case customProxy
    /// Frontier closed-weight model on Factory's Standard pool.
    case standard
    /// Open-weight model eligible for Droid Core's separate free pool.
    case droidCore
    /// `providerLock=factory` but the model is unknown to the classifier.
    case factoryUnknown
}

enum FactorySessionClassifier {

    // MARK: - Droid Core Identification

    /// Open-weight model family prefixes Factory currently designates as
    /// "Core". Matched case-insensitively against `model` and stripped of
    /// the `custom:` prefix and trailing `:cloud-N` suffix the CLI adds
    /// when it routes a Core model through a user proxy.
    ///
    /// Keep this list narrow — better to classify a session as
    /// `.factoryUnknown` (counted against Standard) than to falsely
    /// mark a Premium model as Core and under-report Standard burn.
    static let droidCoreModelPrefixes: [String] = [
        "kimi-k",            // kimi-k2.6, kimi-k2.6:cloud-0
        "glm-",              // glm-5, glm-5.1
        "deepseek-",         // deepseek-v4-pro, deepseek-v4-flash, deepseek-r1
        "minimax-",          // minimax-m2.7
        "qwen",              // qwen3.6-plus, qwen-coder
        "z.ai-glm",          // Z.ai-GLM-5.1 (display-name fallback)
        "llama-",            // llama-3.x open-weight families
        "mistral-",          // mistral, mistral-large open-weight tiers
        "gemma-"             // gemma open-weight family
    ]

    /// Premium frontier prefixes — these are explicitly NOT Droid Core
    /// even when `providerLock=factory`. They always count against
    /// Standard Usage.
    static let premiumModelPrefixes: [String] = [
        "claude-",
        "claude_",
        "gpt-",
        "gpt_",
        "o1-",
        "o3-",
        "o4-",
        "o5-",
        "gemini-",
        "anthropic.",
        "openai."
    ]

    // MARK: - Classification

    /// Returns the billing lane the session ran on.
    static func lane(for session: [String: Any]) -> FactorySessionLane {
        guard let lockRaw = session["providerLock"] as? String else {
            // No providerLock recorded — pre-2026.04 schema. Treat as
            // unknown so it doesn't poison the Factory cap.
            return .customProxy
        }
        let lock = lockRaw.lowercased()
        guard lock == "factory" else {
            // Any other providerLock means the user pointed this session
            // at a custom_models[] entry in config.json (third-party proxies,
            // localhost Ollama, OpenCode-Go, BYOK keys, …). These are
            // user-owned routes and have nothing to do with Factory's
            // rate limits.
            return .customProxy
        }
        let model = normalizeModel(session["model"] as? String ?? "")
        if model.isEmpty { return .factoryUnknown }

        if premiumModelPrefixes.contains(where: { model.hasPrefix($0) }) {
            return .standard
        }
        if droidCoreModelPrefixes.contains(where: { model.hasPrefix($0) }) {
            return .droidCore
        }
        return .factoryUnknown
    }

    /// Strips the `custom:` prefix the CLI adds when a session routes a
    /// Factory-native model through a user proxy, plus the trailing
    /// `:cloud-N` shard suffix. Lowercased so callers can do prefix
    /// matching without re-casing.
    private static func normalizeModel(_ raw: String) -> String {
        var m = raw.lowercased()
        if m.hasPrefix("custom:") {
            m = String(m.dropFirst("custom:".count))
        }
        if let suffix = m.range(of: ":cloud-") {
            m = String(m[..<suffix.lowerBound])
        }
        // Some display names use spaces — collapse for prefix matching.
        m = m.replacingOccurrences(of: " ", with: "-")
        return m
    }

    // MARK: - Token totals helper

    /// Sums input + output + cacheCreate + cacheRead + thinking from a
    /// `tokenUsage` blob. Returns 0 when the blob is missing or every
    /// field is zero — callers should skip sessions that report 0 so
    /// the burn windows stay clean.
    static func totalTokens(in tokenUsage: [String: Any]) -> Int64 {
        func intValue(_ key: String) -> Int64 {
            (tokenUsage[key] as? Int64)
                ?? (tokenUsage[key] as? Int).map(Int64.init)
                ?? (tokenUsage[key] as? Double).map { Int64($0) }
                ?? 0
        }
        return intValue("inputTokens")
            + intValue("outputTokens")
            + intValue("cacheCreationTokens")
            + intValue("cacheReadTokens")
            + intValue("thinkingTokens")
    }
}
