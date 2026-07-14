import Foundation

// MARK: - CLI Launch Environment Redaction (Foundation-pure)
//
// Core-decomposition P-18 (docs/CORE_DECOMPOSITION_PROGRAM.md): the secret-safe
// logging/redaction surface of the CLI launch stack, extracted DOWN from
// `OpenBurnBarLaunchServices/SwitcherCLILAunchService.swift` into the cross-platform
// Kernel so the daemon repoint reaches it via Engine WITHOUT linking the Apple-only,
// AppKit-adjacent `OpenBurnBarLaunchServices` target. `CLILaunchRedactor` is pure
// Foundation (String/Set/Dictionary regex only — zero Kernel or LaunchServices
// symbol), so this is a wholesale relocation with zero behavior change. Consumers:
// the daemon's `OpenBurnBarSwitcherShell` (redacts launch failure detail) and
// AgentLens' CLIBridge, both macOS-only — the `#if os(macOS)` guard is preserved
// verbatim from the origin file (which was wholly `#if os(macOS)`), so the type stays
// macOS-only and never appears off-Apple or on iOS, byte-identical to before.
#if os(macOS)

/// Provides secret-safe logging and redaction utilities for CLI launch operations.
public struct CLILaunchRedactor {
    /// Keys that are considered sensitive and should never appear in logs.
    private static let sensitiveKeys: Set<String> = [
        "API_KEY", "APIKEY", "SECRET", "TOKEN", "PASSWORD", "AUTH",
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY"
    ]

    /// Redacts sensitive patterns from a string for safe logging.
    public static func redactSensitiveData(_ input: String) -> String {
        var result = input

        // Redact sensitive environment key patterns (key=value or key:value)
        // We look for patterns that indicate a secret is present:
        // 1. API key patterns (sk-ant-, sk- followed by 20+ chars, etc.)
        // Note: Longer patterns must come first in alternation to match correctly
        result = result.replacingOccurrences(
            of: #"(?i)(sk-[a-zA-Z0-9]{20,}|sk-ant-)"#,
            with: "[API_KEY_REDACTED]",
            options: .regularExpression
        )

        // 2. Bearer token patterns
        result = result.replacingOccurrences(
            of: #"(?i)Bearer[_\s]+[A-Za-z0-9_\-\.]+"#,
            with: "[TOKEN_REDACTED]",
            options: .regularExpression
        )

        // 3. Generic key=value patterns where value looks like a secret
        // Pattern: word characters followed by = or : followed by what looks like a token/secret
        result = result.replacingOccurrences(
            of: #"(?i)(api_key|apikey|secret|password|token|auth|access_token)[=:][^,\s]+"#,
            with: "[SECRET_REDACTED]",
            options: .regularExpression
        )

        return result
    }

    /// Redacts sensitive environment variables from a dictionary for safe logging.
    public static func redactEnvironment(_ env: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        for (key, value) in env {
            let isSensitive = sensitiveKeys.contains { key.uppercased().contains($0) }
            if isSensitive {
                result[key] = "[REDACTED]"
            } else {
                result[key] = redactSensitiveData(value)
            }
        }

        return result
    }
}

#endif
