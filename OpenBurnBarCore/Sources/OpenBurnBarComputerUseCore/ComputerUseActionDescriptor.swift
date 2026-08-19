import Foundation
import OpenBurnBarKernel

/// Typed action descriptors for every Computer Use tool. The Mac
/// dispatcher converts a `BurnBarToolInvocation`'s loosely-typed
/// `arguments` into one of these, runs scope + approval + deny gates
/// against it, and then converts to the concrete dispatcher payload
/// (Playwright JSON-RPC, CGEvent, etc.). The two-step conversion keeps
/// the gate code pure-Swift / no AppKit / no Playwright dependencies so
/// it can live in this cross-platform-safe core target.
public enum ComputerUseAction: Codable, Hashable, Sendable {
    case browser(BrowserAction)
    case safari(SafariActionDescriptor)
    case macInput(MacInputAction)
    case macInspect(MacInspectAction)
    case phoneIntent(PhoneControlIntent)
    case remoteClipboard(RemoteClipboardActionDescriptor)
}

public extension ComputerUseAction {
    /// Human-readable summary surfaced in the approval sheet and the
    /// audit chain. Keep terse — the sheet shows the full action card
    /// alongside it.
    func executableSummary(forApproval context: ComputerUseScopeContext? = nil) -> String {
        switch self {
        case .browser(let action):
            return action.executableSummary(forApproval: context)
        case .safari(let action):
            return action.executableSummary(forApproval: context)
        case .macInput(let action):
            return action.executableSummary(forApproval: context)
        case .macInspect(let action):
            return action.executableSummary(forApproval: context)
        case .phoneIntent(let intent):
            return intent.executableSummary(forApproval: context)
        case .remoteClipboard(let action):
            return action.executableSummary(forApproval: context)
        }
    }

    /// String discriminator used in the audit chain's `action.kind`
    /// field. Stable across phases.
    var auditKind: String {
        switch self {
        case .browser(let a): return "browser.\(a.kind.rawValue)"
        case .safari(let a): return "safari.\(a.kind.rawValue)"
        case .macInput(let a): return "mac.input.\(a.kind.rawValue)"
        case .macInspect(let a): return "mac.inspect.\(a.kind.rawValue)"
        case .phoneIntent(let i): return "phone.\(i.kind.rawValue)"
        case .remoteClipboard(let a): return "clipboard.\(a.kind.rawValue)"
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

// MARK: - Safari Web Extension actions (real-session Path B)

public struct SafariActionDescriptor: Codable, Hashable, Sendable {
    public let kind: BurnBarSafariActionKind
    public let safariSessionId: String
    public let tabId: Int?
    public let expectedNavigationEpoch: Int?
    public let selector: String?
    public let text: String?
    public let url: String?
    public let navigationOperation: BurnBarSafariNavigationOperation?
    public let key: String?
    public let value: String?
    public let positionX: Double?
    public let positionY: Double?
    public let deltaX: Double?
    public let deltaY: Double?
    public let script: String?
    public let timeoutMillis: Int

    public init(
        kind: BurnBarSafariActionKind,
        safariSessionId: String,
        tabId: Int? = nil,
        expectedNavigationEpoch: Int? = nil,
        selector: String? = nil,
        text: String? = nil,
        url: String? = nil,
        navigationOperation: BurnBarSafariNavigationOperation? = nil,
        key: String? = nil,
        value: String? = nil,
        positionX: Double? = nil,
        positionY: Double? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        script: String? = nil,
        timeoutMillis: Int = BurnBarSafariProtocol.defaultCommandTimeoutMillis
    ) {
        self.kind = kind
        self.safariSessionId = safariSessionId
        self.tabId = tabId
        self.expectedNavigationEpoch = expectedNavigationEpoch
        self.selector = selector
        self.text = text
        self.url = url
        self.navigationOperation = navigationOperation
        self.key = key
        self.value = value
        self.positionX = positionX
        self.positionY = positionY
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.script = script
        self.timeoutMillis = timeoutMillis
    }

    public var isReadOnly: Bool { kind.isReadOnly }

    public func executableSummary(forApproval context: ComputerUseScopeContext? = nil) -> String {
        let host = context?.url.flatMap(extractHost)
            ?? url.flatMap(extractHost)
            ?? "this Safari tab"
        switch kind {
        case .pageContext:
            return "Read page context from \(host)"
        case .screenshot:
            return "Capture the visible Safari viewport on \(host)"
        case .fullPageScreenshot:
            return "Capture the full Safari page on \(host)"
        case .click:
            if let selector { return "Click \(quoted(selector)) on \(host)" }
            if let positionX, let positionY {
                return "Click at (\(formatCoordinate(positionX)), \(formatCoordinate(positionY))) on \(host)"
            }
            return "Click on \(host)"
        case .type:
            let target = selector.map(quoted) ?? "the focused field"
            return "Type \(redactedTextSummary(text)) into \(target) on \(host)"
        case .pressKey:
            return "Press \(key ?? "?") on \(host)"
        case .scroll:
            return "Scroll \(scrollSummary(deltaX: deltaX, deltaY: deltaY)) on \(host)"
        case .hover:
            return "Hover \(selector.map(quoted) ?? "the target") on \(host)"
        case .focus:
            return "Focus \(selector.map(quoted) ?? "the target") on \(host)"
        case .selectOption:
            return "Select \(quoted(value ?? "<value>")) in \(quoted(selector ?? "<field>")) on \(host)"
        case .navigate:
            switch navigationOperation {
            case .url:
                return "Navigate Safari to \(url ?? "?")"
            case .back:
                return "Navigate Safari back on \(host)"
            case .forward:
                return "Navigate Safari forward on \(host)"
            case .reload:
                return "Reload \(host) in Safari"
            case nil:
                return "Navigate Safari on \(host)"
            }
        case .openTab:
            return "Open a Safari tab for \(url ?? "the requested page")"
        case .closeTab:
            return "Close the owned Safari tab \(tabId.map(String.init) ?? "")".trimmingCharacters(in: .whitespaces)
        case .listTabs:
            return "List Safari tabs visible to this extension session"
        case .waitFor:
            return "Wait for \(selector.map(quoted) ?? "the requested page state") on \(host)"
        case .runJavaScript:
            return "Run approved JavaScript (\(script?.utf8.count ?? 0) bytes) on \(host)"
        case .extract:
            return "Extract \(selector.map(quoted) ?? "page content") from \(host)"
        case .abort:
            return "Stop the Safari agent session"
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
        case pointerMove = "pointer_move"
        case pointerClick = "pointer_click"
    }

    public let kind: Kind
    public let displayX: Int?
    public let displayY: Int?
    public let dragEndX: Int?
    public let dragEndY: Int?
    public let deltaX: Int?
    public let deltaY: Int?
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
        deltaX: Int? = nil,
        deltaY: Int? = nil,
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
        self.deltaX = deltaX
        self.deltaY = deltaY
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
        case .pointerMove:
            return "Move pointer in \(app)"
        case .pointerClick:
            return "Click current pointer in \(app)"
        }
    }
}

// MARK: - Remote clipboard actions (Path D)

public struct RemoteClipboardActionDescriptor: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case pasteToMac = "paste_to_mac"
        case grabFromMac = "grab_from_mac"
    }

    public let kind: Kind
    public let requestId: String
    public let contentType: String
    public let byteCount: Int?
    public let maxBytes: Int

    public init(
        kind: Kind,
        requestId: String,
        contentType: String,
        byteCount: Int? = nil,
        maxBytes: Int
    ) {
        self.kind = kind
        self.requestId = requestId
        self.contentType = contentType
        self.byteCount = byteCount
        self.maxBytes = maxBytes
    }

    public func executableSummary(forApproval context: ComputerUseScopeContext? = nil) -> String {
        let app = context?.bundleId ?? "Mac"
        switch kind {
        case .pasteToMac:
            return "Paste phone clipboard text into \(app)"
        case .grabFromMac:
            return "Copy Mac clipboard text from \(app)"
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
        case contextTarget = "context_target"
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
        case .contextTarget:
            return "Phone context handoff for instruction \(quoted(text ?? "")) on \(app)"
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

private func formatCoordinate(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func redactedTextSummary(_ text: String?) -> String {
    guard let text, !text.isEmpty else { return "text" }
    return "\(text.count) character\(text.count == 1 ? "" : "s")"
}

private func scrollSummary(deltaX: Double?, deltaY: Double?) -> String {
    let x = deltaX.map(formatCoordinate) ?? "0"
    let y = deltaY.map(formatCoordinate) ?? "0"
    return "by (\(x), \(y))"
}
