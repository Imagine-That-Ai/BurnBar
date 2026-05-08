import Foundation
import CoreGraphics

// MARK: - Pretext Value Types
//
// Public mirror of the @chenglou/pretext API in Swift value types. Handles
// reference state living inside the Pretext WKWebView; Swift never sees the
// underlying JS structures, only opaque integer IDs that round-trip through
// the bridge.
//
// All measurements are CSS pixels. Pretext's measurement basis is the canvas
// font metric, which matches CSS box dimensions for text rendering. Do not
// confuse with logical points or device pixels.

/// Opaque handle to a `PreparedText` or `PreparedTextWithSegments` living
/// inside the Pretext engine. Released via `PretextEngine.release(_:)`.
public struct PretextHandle: Hashable, Codable, Sendable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

/// Opaque handle to a prepared rich-inline run.
public struct PretextRichHandle: Hashable, Codable, Sendable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

/// Mirror of `prepare()` / `prepareWithSegments()` options.
public struct PretextOptions: Hashable, Codable, Sendable {
    public enum WhiteSpace: String, Codable, Sendable {
        case normal
        case preWrap = "pre-wrap"
    }

    public enum WordBreak: String, Codable, Sendable {
        case normal
        case keepAll = "keep-all"
    }

    public var whiteSpace: WhiteSpace?
    public var wordBreak: WordBreak?
    /// CSS pixel value, matching the JS API.
    public var letterSpacing: Double?

    public init(
        whiteSpace: WhiteSpace? = nil,
        wordBreak: WordBreak? = nil,
        letterSpacing: Double? = nil
    ) {
        self.whiteSpace = whiteSpace
        self.wordBreak = wordBreak
        self.letterSpacing = letterSpacing
    }

    /// Default normal-flow options.
    public static let normal = PretextOptions()
}

/// Result of `layout()` — paragraph height + line count.
public struct PretextLayoutResult: Hashable, Sendable {
    public let height: CGFloat
    public let lineCount: Int

    public init(height: CGFloat, lineCount: Int) {
        self.height = height
        self.lineCount = lineCount
    }
}

/// One line produced by `layoutWithLines()`.
public struct PretextLine: Hashable, Sendable {
    public let text: String
    public let width: CGFloat

    public init(text: String, width: CGFloat) {
        self.text = text
        self.width = width
    }
}

/// Result of `layoutWithLines()` — height, line count, and the actual lines.
public struct PretextLinesResult: Hashable, Sendable {
    public let height: CGFloat
    public let lineCount: Int
    public let lines: [PretextLine]

    public init(height: CGFloat, lineCount: Int, lines: [PretextLine]) {
        self.height = height
        self.lineCount = lineCount
        self.lines = lines
    }
}

/// Result of `measureLineStats()`.
public struct PretextLineStats: Hashable, Sendable {
    public let lineCount: Int
    public let maxLineWidth: CGFloat

    public init(lineCount: Int, maxLineWidth: CGFloat) {
        self.lineCount = lineCount
        self.maxLineWidth = maxLineWidth
    }
}

// MARK: - Rich Inline

/// One fragment of input for `prepareRichInline()`.
///
/// `font` uses the same canvas string format as everywhere else
/// (`"500 17px Inter"`).
///
/// Set `breakNever` to `true` for atomic items like chips and mentions, and
/// pass `extraWidth` to reserve space for pill chrome.
public struct PretextRichInlineItem: Hashable, Codable, Sendable {
    public let text: String
    public let font: String
    public var breakNever: Bool
    public var extraWidth: CGFloat

    public init(
        text: String,
        font: String,
        breakNever: Bool = false,
        extraWidth: CGFloat = 0
    ) {
        self.text = text
        self.font = font
        self.breakNever = breakNever
        self.extraWidth = extraWidth
    }
}

/// One fragment of laid-out rich-inline text. `itemIndex` points back into
/// the original `[PretextRichInlineItem]` so callers can recover the source
/// font, color, and any caller-owned chrome.
public struct PretextRichFragment: Hashable, Sendable {
    public let text: String
    public let itemIndex: Int
    public let gapBefore: CGFloat

    public init(text: String, itemIndex: Int, gapBefore: CGFloat) {
        self.text = text
        self.itemIndex = itemIndex
        self.gapBefore = gapBefore
    }
}

/// One line of laid-out rich-inline text.
public struct PretextRichLine: Hashable, Sendable {
    public let width: CGFloat
    public let fragments: [PretextRichFragment]

    public init(width: CGFloat, fragments: [PretextRichFragment]) {
        self.width = width
        self.fragments = fragments
    }
}

// MARK: - Errors

public enum PretextError: Error, CustomStringConvertible, Sendable {
    case engineUnavailable
    case timeout
    case invalidResponse
    case bridgeError(String)

    public var description: String {
        switch self {
        case .engineUnavailable: return "Pretext engine is not loaded yet."
        case .timeout:           return "Pretext call timed out."
        case .invalidResponse:   return "Pretext returned a malformed response."
        case .bridgeError(let m): return "Pretext bridge error: \(m)"
        }
    }
}
