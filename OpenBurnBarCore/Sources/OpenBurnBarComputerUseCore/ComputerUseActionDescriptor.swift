import Foundation

/// Typed action descriptors for every Computer Use tool. The Mac
/// dispatcher converts a `BurnBarToolInvocation`'s loosely-typed
/// `arguments` into one of these, runs scope + approval + deny gates
/// against it, and then converts to the concrete dispatcher payload
/// (Playwright JSON-RPC, CGEvent, etc.). The two-step conversion keeps
/// the gate code pure-Swift / no AppKit / no Playwright dependencies so
/// it can live in this cross-platform-safe core target.
public enum ComputerUseAction: Codable, Hashable, Sendable {
    case browser(BrowserAction)
    case macInput(MacInputAction)
    case macInspect(MacInspectAction)
    case phoneIntent(PhoneControlIntent)
}

public extension ComputerUseAction {
    /// Human-readable summary surfaced in the approval sheet and the
    /// audit chain. Keep terse — the sheet shows the full action card
    /// alongside it.
    func executableSummary(forApproval context: ComputerUseScopeContext? = nil) -> String {
        switch self {
        case .browser(let action):
            return action.executableSummary(forApproval: context)
        case .macInput(let action):
            return action.executableSummary(forApproval: context)
        case .macInspect(let action):
            return action.executableSummary(forApproval: context)
        case .phoneIntent(let intent):
            return intent.executableSummary(forApproval: context)
        }
    }

    /// String discriminator used in the audit chain's `action.kind`
    /// field. Stable across phases.
    var auditKind: String {
        switch self {
        case .browser(let a): return "browser.\(a.kind.rawValue)"
        case .macInput(let a): return "mac.input.\(a.kind.rawValue)"
        case .macInspect(let a): return "mac.inspect.\(a.kind.rawValue)"
        case .phoneIntent(let i): return "phone.\(i.kind.rawValue)"
        }
    }
}

// MARK: - Browser actions (Path B)

public struct BrowserAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case click
        case fill
        case goto
        case key
        case select
        case screenshot
        case extract
    }

    public let kind: Kind
    public let selector: String?
    public let text: String?
    public let url: String?
    public let key: String?
    public let value: String?
    /// Optional coordinate-based click target — Playwright accepts
    /// `position` as a fallback when a selector cannot be resolved on a
    /// shadow-DOM page (risk 10 mitigation in the master plan).
    public let positionX: Int?
    public let positionY: Int?
    public let timeoutMillis: Int

    public init(
        kind: Kind,
        selector: String? = nil,
        text: String? = nil,
        url: String? = nil,
        key: String? = nil,
        value: String? = nil,
        positionX: Int? = nil,
        positionY: Int? = nil,
        timeoutMillis: Int = 10_000
    ) {
        self.kind = kind
        self.selector = selector
        self.text = text
        self.url = url
        self.key = key
        self.value = value
        self.positionX = positionX
        self.positionY = positionY
        self.timeoutMillis = timeoutMillis
    }

    public func executableSummary(forApproval context: ComputerUseScopeContext? = nil) -> String {
        let host = context?.url.flatMap(extractHost) ?? "browser"
        switch kind {
        case .click:
            if let selector { return "Click \(quoted(selector)) on \(host)" }
            if let positionX, let positionY {
                return "Click at (\(positionX), \(positionY)) on \(host)"
            }
            return "Click on \(host)"
        case .fill:
            return "Type \(quoted(text ?? "<text>")) into \(quoted(selector ?? "<field>")) on \(host)"
        case .goto:
            return "Navigate to \(url ?? "?")"
        case .key:
            return "Press \(key ?? "?") on \(host)"
        case .select:
            return "Select \(quoted(value ?? "<value>")) in \(quoted(selector ?? "<field>")) on \(host)"
        case .screenshot:
            return "Screenshot the page on \(host)"
        case .extract:
            return "Extract content of \(quoted(selector ?? "<root>")) from \(host)"
        }
    }
}

// MARK: - Mac input actions (Path C)

public struct MacInputAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case click
        case type
        case key
        case shortcut
        case dragDrop = "drag_drop"
        case scroll
    }

    public let kind: Kind
    public let displayX: Int?
    public let displayY: Int?
    public let dragEndX: Int?
    public let dragEndY: Int?
    public let mouseButton: Int
    public let text: String?
    public let key: String?
    public let modifiers: [String]?

    public init(
        kind: Kind,
        displayX: Int? = nil,
        displayY: Int? = nil,
        dragEndX: Int? = nil,
        dragEndY: Int? = nil,
        mouseButton: Int = 0,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String]? = nil
    ) {
        self.kind = kind
        self.displayX = displayX
        self.displayY = displayY
        self.dragEndX = dragEndX
        self.dragEndY = dragEndY
        self.mouseButton = mouseButton
        self.text = text
        self.key = key
        self.modifiers = modifiers
    }

    public func executableSummary(forApproval context: ComputerUseScopeContext? = nil) -> String {
        let app = context?.bundleId ?? "Mac"
        switch kind {
        case .click:
            if let displayX, let displayY {
                return "Click at (\(displayX), \(displayY)) in \(app)"
            }
            return "Click in \(app)"
        case .type:
            return "Type \(quoted(text ?? "<text>")) in \(app)"
        case .key:
            return "Press \(key ?? "?") in \(app)"
        case .shortcut:
            let combo = ((modifiers ?? []) + [key].compactMap { $0 }).joined(separator: "+")
            return "Send shortcut \(combo) in \(app)"
        case .dragDrop:
            let from = (displayX.map(String.init) ?? "?") + "," + (displayY.map(String.init) ?? "?")
            let to = (dragEndX.map(String.init) ?? "?") + "," + (dragEndY.map(String.init) ?? "?")
            return "Drag from (\(from)) to (\(to)) in \(app)"
        case .scroll:
            if let displayX, let displayY {
                return "Scroll at (\(displayX), \(displayY)) in \(app)"
            }
            return "Scroll in \(app)"
        }
    }
}

// MARK: - Mac inspect actions (Path C, read-only)

public struct MacInspectAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case accessibility
    }

    public let kind: Kind
    public let displayX: Int?
    public let displayY: Int?

    public init(kind: Kind, displayX: Int? = nil, displayY: Int? = nil) {
        self.kind = kind
        self.displayX = displayX
        self.displayY = displayY
    }

    public func executableSummary(forApproval context: ComputerUseScopeContext? = nil) -> String {
        let app = context?.bundleId ?? "Mac"
        if let displayX, let displayY {
            return "Inspect element at (\(displayX), \(displayY)) in \(app)"
        }
        return "Inspect frontmost window in \(app)"
    }
}

// MARK: - Phone control intents (Path D)

public struct PhoneControlIntent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case tap
        case dragStart = "drag_start"
        case dragMove = "drag_move"
        case dragEnd = "drag_end"
        case type
        case shortcut
        case scroll
        case panic
    }

    public let kind: Kind
    public let normalizedX: Double?
    public let normalizedY: Double?
    public let normalizedX2: Double?
    public let normalizedY2: Double?
    public let text: String?
    public let key: String?
    public let modifiers: [String]?

    public init(
        kind: Kind,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        normalizedX2: Double? = nil,
        normalizedY2: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String]? = nil
    ) {
        self.kind = kind
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedX2 = normalizedX2
        self.normalizedY2 = normalizedY2
        self.text = text
        self.key = key
        self.modifiers = modifiers
    }

    public func executableSummary(forApproval context: ComputerUseScopeContext? = nil) -> String {
        let app = context?.bundleId ?? "Mac"
        switch kind {
        case .tap:
            return "Phone tap at (\(formatNormalized(normalizedX)), \(formatNormalized(normalizedY))) on \(app)"
        case .dragStart:
            return "Phone drag start at (\(formatNormalized(normalizedX)), \(formatNormalized(normalizedY)))"
        case .dragMove:
            return "Phone drag move to (\(formatNormalized(normalizedX)), \(formatNormalized(normalizedY)))"
        case .dragEnd:
            return "Phone drag end at (\(formatNormalized(normalizedX)), \(formatNormalized(normalizedY)))"
        case .type:
            return "Phone type \(quoted(text ?? "<text>")) in \(app)"
        case .shortcut:
            let combo = ((modifiers ?? []) + [key].compactMap { $0 }).joined(separator: "+")
            return "Phone shortcut \(combo) in \(app)"
        case .scroll:
            return "Phone scroll on \(app)"
        case .panic:
            return "Phone panic halt"
        }
    }
}

// MARK: - Local helpers (file-private to avoid extending Foundation publicly)

private func quoted(_ value: String) -> String { "‘\(value)’" }

private func extractHost(_ url: String) -> String? {
    guard let parsed = URL(string: url), let host = parsed.host else { return nil }
    return host
}

private func formatNormalized(_ value: Double?) -> String {
    guard let value else { return "?" }
    return String(format: "%.2f", value)
}
