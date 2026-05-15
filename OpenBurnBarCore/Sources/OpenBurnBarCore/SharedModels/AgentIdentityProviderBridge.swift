import Foundation

// MARK: - Agent Identity → Provider Bridge
//
// Maps each `AgentIdentity` (built-in or user-installed) to an
// `AgentProvider` so the existing `UnifiedProviderLogoView` can render
// the real bundled brand logo (Claude squiggle, OpenAI ring, Pi pi-glyph,
// OpenClaw burst, etc.) anywhere Hermes Square renders an agent avatar.
//
// For built-ins the map is exhaustive. For user-installed agents we
// inspect the URI for a vendor segment (`agent://third-party/<vendor>/...`)
// and try `AgentProvider.fromPersistedToken(vendor)`. When that fails the
// caller falls back to the gradient + glyph treatment so the surface
// degrades gracefully.

extension AgentIdentity {

    /// Best-effort `AgentProvider` for this identity. Built-ins always
    /// resolve; user-installed agents resolve when their URI's vendor
    /// segment matches a known provider token.
    public var resolvedProvider: AgentProvider? {
        // Built-in runtimes map directly.
        if let runtimeID {
            return Self.builtInProvider(for: runtimeID)
        }
        // Third-party / user-installed: parse the URI for a vendor token
        // and try to match it. `agent://third-party/<vendor>/<token>`
        // → vendor segment.
        let prefix = "agent://third-party/"
        guard id.hasPrefix(prefix) else { return nil }
        let tail = id.dropFirst(prefix.count)
        let vendor = tail.split(separator: "/").first.map(String.init) ?? ""
        return AgentProvider.fromPersistedToken(vendor)
    }

    /// Stable provider bridge for built-in runtimes. Centralised so the
    /// rest of the app can't get this wrong.
    public static func builtInProvider(for runtime: AssistantRuntimeID) -> AgentProvider {
        switch runtime {
        case .hermes:   return .hermes
        case .pi:       return .piAgent
        case .claude:   return .claudeCode
        case .codex:    return .codex
        case .openClaw: return .openClaw
        }
    }
}
