import Foundation

// MARK: - Hermes Atom
//
// Typed enum of "conversation atoms" — entities that Hermes references in
// chat which the OpenBurnBar app already has dedicated UI for. Atoms are
// emitted by Hermes (or detected from prose) and rendered as atomic
// inline chips that, when tapped, navigate to the matching native view.
//
// Pretext rich-inline ensures these chips never break across lines and
// that prose flows naturally around them.

/// Time window selector reused across the app's analytics surfaces.
public enum HermesAtomWindow: String, Hashable, Codable, Sendable, CaseIterable {
    case today
    case yesterday
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case all

    public var displayLabel: String {
        switch self {
        case .today:      return "today"
        case .yesterday:  return "yesterday"
        case .sevenDays:  return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .all:        return "all time"
        }
    }
}

/// Categorical group of token-volume scopes.
public enum HermesAtomTokenScope: String, Hashable, Codable, Sendable {
    case today
    case session
    case run
    case lifetime
    case unspecified

    public var displayLabel: String {
        switch self {
        case .today:       return "today"
        case .session:     return "this session"
        case .run:         return "this run"
        case .lifetime:    return "lifetime"
        case .unspecified: return ""
        }
    }
}

/// One conversation atom — a strongly-typed reference to an entity in the
/// app. Each case carries enough data to navigate to the entity, plus a
/// `HermesAtomKind` that drives icon / accent / label format choices.
public enum HermesAtom: Hashable, Sendable {
    /// A monetary cost across some time window. Decimal-as-Double avoids
    /// the Codable headache of bridging Decimal through a JSON-able
    /// serialization layer; cost atoms are display-only.
    case cost(amount: Double, window: HermesAtomWindow)
    /// A specific session, identified by its persistent ID.
    case session(id: String)
    /// A provider (e.g. anthropic, openai, kimi). Token matches
    /// `AgentProvider.fromPersistedToken` in the app.
    case provider(token: String)
    /// A specific model, by ID (e.g. `claude-sonnet-4.7`).
    case model(id: String)
    /// A time window selector (e.g. tap to switch dashboard to 7d).
    case window(HermesAtomWindow)
    /// A tool the assistant called.
    case tool(name: String)
    /// A project tracked in OpenBurnBar.
    case project(id: String)
    /// A token volume — counts that the app already surfaces in headers
    /// and detail sheets.
    case tokens(value: Int, scope: HermesAtomTokenScope)
    /// Quota for a specific provider, expressed as a percentage used.
    case quota(provider: String, percent: Int)
    /// A Hermes runtime profile (e.g. `hermes`, `relay`, `local`).
    case runtime(profile: String)

    public var kind: HermesAtomKind {
        switch self {
        case .cost:     return .cost
        case .session:  return .session
        case .provider: return .provider
        case .model:    return .model
        case .window:   return .window
        case .tool:     return .tool
        case .project:  return .project
        case .tokens:   return .tokens
        case .quota:    return .quota
        case .runtime:  return .runtime
        }
    }

    /// Default label used when the source label is missing or whitespace-
    /// only. Keeps the rendered chip from collapsing.
    public var fallbackLabel: String {
        switch self {
        case .cost(let amount, let window):
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.maximumFractionDigits = 2
            let cost = formatter.string(from: NSNumber(value: amount)) ?? "$\(amount)"
            return "\(cost) \(window.displayLabel)"
        case .session(let id):     return "session \(id.prefix(8))"
        case .provider(let token): return token.capitalized
        case .model(let id):       return id
        case .window(let w):       return w.displayLabel
        case .tool(let name):      return name
        case .project(let id):     return id
        case .tokens(let value, let scope):
            let formatted = HermesAtom.formatTokenCount(value)
            return scope == .unspecified ? "\(formatted) tokens" : "\(formatted) \(scope.displayLabel)"
        case .quota(let provider, let percent):
            return "\(percent)% \(provider.capitalized)"
        case .runtime(let profile):
            return profile.capitalized
        }
    }

    /// Human-friendly token count formatter — `12.4k`, `1.2M`, etc.
    public static func formatTokenCount(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        if value < 1_000_000 {
            let k = Double(value) / 1_000
            return String(format: "%.1fk", k)
        }
        let m = Double(value) / 1_000_000
        return String(format: "%.1fM", m)
    }
}

// MARK: - Atom Kind (presentation metadata)

/// Visual / behavioral category for an atom. Maps to icon, accent color
/// token name, and short display category. The actual SF Symbol + Color
/// resolution lives in each app's UI layer (different design systems for
/// iOS vs macOS).
public enum HermesAtomKind: String, Hashable, Codable, Sendable, CaseIterable {
    case cost
    case session
    case provider
    case model
    case window
    case tool
    case project
    case tokens
    case quota
    case runtime

    /// SF Symbol identifier suitable for the chip's leading glyph.
    public var systemImage: String {
        switch self {
        case .cost:     return "dollarsign.circle.fill"
        case .session:  return "rectangle.stack.fill"
        case .provider: return "externaldrive.connected.to.line.below"
        case .model:    return "cpu"
        case .window:   return "calendar"
        case .tool:     return "wrench.and.screwdriver.fill"
        case .project:  return "folder.fill"
        case .tokens:   return "number"
        case .quota:    return "gauge.with.dots.needle.67percent"
        case .runtime:  return "antenna.radiowaves.left.and.right"
        }
    }

    /// Short category label used by the detail sheet header.
    public var categoryLabel: String {
        switch self {
        case .cost:     return "Cost"
        case .session:  return "Session"
        case .provider: return "Provider"
        case .model:    return "Model"
        case .window:   return "Window"
        case .tool:     return "Tool"
        case .project:  return "Project"
        case .tokens:   return "Tokens"
        case .quota:    return "Quota"
        case .runtime:  return "Runtime"
        }
    }

    /// One-line explanation used inside the detail sheet.
    public var description: String {
        switch self {
        case .cost:     return "Open the burn detail for this time window."
        case .session:  return "Open this session's detail view."
        case .provider: return "Open this provider's dashboard."
        case .model:    return "Open this model's detail or pick it as default."
        case .window:   return "Switch the dashboard to this time window."
        case .tool:     return "See where this tool was invoked in the run."
        case .project:  return "Open this project's detail."
        case .tokens:   return "Open the token-usage detail."
        case .quota:    return "Open quota detail for this provider."
        case .runtime:  return "Open Hermes runtime details for this profile."
        }
    }
}
