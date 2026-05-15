import Foundation

// MARK: - Card Envelope (Hermes Square §6.1 / §6.6)
//
// The discriminated union an agent emits over its stream. The host
// validates and renders — agents never touch our view tree directly.
//
// Pattern: WeChat dual-thread isolation
// (https://developers.weixin.qq.com/miniprogram/en/dev/framework/runtime/env.html) +
// MCP-UI shapes
// (https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/) +
// W3C MiniApp manifest
// (https://www.w3.org/TR/miniapp-packaging/).
//
// Render targets (one SwiftUI view per case):
//   • text(markdown:)        — `CardTextView`
//   • table(headers:rows:)   — `CardTableView`
//   • diff(file:before:after:)— `CardDiffView`
//   • image(url:alt:)        — `CardImageView`
//   • chart(spec:)           — `CardChartView`
//   • approval(prompt:options:)— `CardApprovalView`
//   • mission(snapshot:)     — `CardMissionView` (reuses `MissionConsoleActiveTile`)
//   • custom(schema:url:)    — `CardCustomView` (sandboxed mini-program host)
//
// Host budget gate: every envelope encodes to ≤ 2 MB. The renderer rejects
// anything heavier and surfaces a `.tooLarge` placeholder card.

public enum CardEnvelope: Codable, Sendable, Hashable {
    case text(CardText)
    case table(CardTable)
    case diff(CardDiff)
    case image(CardImage)
    case chart(CardChart)
    case approval(CardApproval)
    case mission(CardMissionRef)
    case custom(CardCustom)
    case tooLarge(CardTooLarge)
    case unknown(String)

    /// Stable kind discriminator. Mirrors manifest's `CardSurface.kind`.
    public var kind: String {
        switch self {
        case .text:      return "text"
        case .table:     return "table"
        case .diff:      return "diff"
        case .image:     return "image"
        case .chart:     return "chart"
        case .approval:  return "approval"
        case .mission:   return "mission"
        case .custom:    return "custom"
        case .tooLarge:  return "too_large"
        case .unknown:   return "unknown"
        }
    }

    // Wire shape: `{ "kind": "text", "payload": { "markdown": "..." } }`.
    private enum CodingKeys: String, CodingKey {
        case kind, payload, reason, label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            self = .text(try container.decode(CardText.self, forKey: .payload))
        case "table":
            self = .table(try container.decode(CardTable.self, forKey: .payload))
        case "diff":
            self = .diff(try container.decode(CardDiff.self, forKey: .payload))
        case "image":
            self = .image(try container.decode(CardImage.self, forKey: .payload))
        case "chart":
            self = .chart(try container.decode(CardChart.self, forKey: .payload))
        case "approval":
            self = .approval(try container.decode(CardApproval.self, forKey: .payload))
        case "mission":
            self = .mission(try container.decode(CardMissionRef.self, forKey: .payload))
        case "custom":
            self = .custom(try container.decode(CardCustom.self, forKey: .payload))
        case "too_large":
            self = .tooLarge(try container.decode(CardTooLarge.self, forKey: .payload))
        default:
            let label = (try? container.decode(String.self, forKey: .label)) ?? kind
            self = .unknown(label)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .text(let p):     try container.encode(p, forKey: .payload)
        case .table(let p):    try container.encode(p, forKey: .payload)
        case .diff(let p):     try container.encode(p, forKey: .payload)
        case .image(let p):    try container.encode(p, forKey: .payload)
        case .chart(let p):    try container.encode(p, forKey: .payload)
        case .approval(let p): try container.encode(p, forKey: .payload)
        case .mission(let p):  try container.encode(p, forKey: .payload)
        case .custom(let p):   try container.encode(p, forKey: .payload)
        case .tooLarge(let p): try container.encode(p, forKey: .payload)
        case .unknown(let s):  try container.encode(s, forKey: .label)
        }
    }
}

// MARK: - Payload structs

public struct CardText: Codable, Sendable, Hashable {
    public let markdown: String
    public let footnote: String?
    public init(markdown: String, footnote: String? = nil) {
        self.markdown = markdown
        self.footnote = footnote
    }
}

public struct CardTable: Codable, Sendable, Hashable {
    public let headers: [String]
    public let rows: [[String]]
    public let caption: String?
    public init(headers: [String], rows: [[String]], caption: String? = nil) {
        self.headers = headers
        self.rows = rows
        self.caption = caption
    }
}

public struct CardDiff: Codable, Sendable, Hashable {
    public let file: String
    public let before: String
    public let after: String
    public let language: String?
    public init(file: String, before: String, after: String, language: String? = nil) {
        self.file = file
        self.before = before
        self.after = after
        self.language = language
    }
}

public struct CardImage: Codable, Sendable, Hashable {
    public let url: String
    public let alt: String
    public let widthHint: Int?
    public let heightHint: Int?
    public init(url: String, alt: String, widthHint: Int? = nil, heightHint: Int? = nil) {
        self.url = url
        self.alt = alt
        self.widthHint = widthHint
        self.heightHint = heightHint
    }
}

public struct CardChart: Codable, Sendable, Hashable {
    /// Vega-Lite spec or our compact `InsightWidget` spec. Discriminated
    /// internally by the renderer.
    public let spec: String
    public let format: Format

    public enum Format: String, Codable, Sendable, Hashable {
        case vegaLite = "vega_lite"
        case insightWidget = "insight_widget"
    }

    public init(spec: String, format: Format = .vegaLite) {
        self.spec = spec
        self.format = format
    }
}

public struct CardApproval: Codable, Sendable, Hashable {
    public let prompt: String
    public let detail: String?
    public let options: [Option]
    /// Optional ID the host echoes back when the user picks. Lets agents
    /// correlate the response.
    public let correlationID: String?

    public struct Option: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let label: String
        public let kind: Kind

        public enum Kind: String, Codable, Sendable, Hashable {
            case primary       // default approve
            case secondary     // alternate
            case destructive   // deny
        }

        public init(id: String, label: String, kind: Kind = .secondary) {
            self.id = id
            self.label = label
            self.kind = kind
        }
    }

    public init(prompt: String, detail: String? = nil, options: [Option], correlationID: String? = nil) {
        self.prompt = prompt
        self.detail = detail
        self.options = options
        self.correlationID = correlationID
    }
}

public struct CardMissionRef: Codable, Sendable, Hashable {
    /// Mission ID — the host looks it up in the live mission store and
    /// renders a `MissionConsoleActiveTile` inline. Keeps the card payload
    /// tiny.
    public let missionID: String
    public init(missionID: String) {
        self.missionID = missionID
    }
}

public struct CardCustom: Codable, Sendable, Hashable {
    /// Schema URL — the host validates against it before rendering.
    public let schemaURL: String
    /// Sandbox URL — the actual mini-program HTML/JS loaded into a strict
    /// WKWebView / WebView with CSP locked down.
    public let sandboxURL: String
    /// Static height hint so the host can pre-allocate the card frame.
    public let heightHint: Int
    public init(schemaURL: String, sandboxURL: String, heightHint: Int = 240) {
        self.schemaURL = schemaURL
        self.sandboxURL = sandboxURL
        self.heightHint = heightHint
    }
}

public struct CardTooLarge: Codable, Sendable, Hashable {
    public let attemptedBytes: Int
    public let maxBytes: Int
    public let kindAttempted: String
    public init(attemptedBytes: Int, maxBytes: Int = 2_097_152, kindAttempted: String) {
        self.attemptedBytes = attemptedBytes
        self.maxBytes = maxBytes
        self.kindAttempted = kindAttempted
    }
}

// MARK: - Budget gate

extension CardEnvelope {
    /// Plan-mandated per-card max bytes (§2 Pillar 3, §8 anti-pattern 6).
    public static let maxPayloadBytes = 2_097_152 // 2 MB

    /// Try to construct from raw JSON, applying the 2 MB budget gate. If
    /// the JSON exceeds the budget, returns a `.tooLarge` placeholder
    /// instead of failing — the host can then show a stub card without
    /// crashing the agent's whole stream.
    public static func fromJSON(_ raw: Data, declaredKind: String? = nil) -> CardEnvelope {
        if raw.count > maxPayloadBytes {
            return .tooLarge(CardTooLarge(
                attemptedBytes: raw.count,
                kindAttempted: declaredKind ?? "unknown"
            ))
        }
        let decoder = JSONDecoder()
        if let env = try? decoder.decode(CardEnvelope.self, from: raw) {
            return env
        }
        return .unknown(declaredKind ?? "decode_failed")
    }

    /// Convenience: encode with the budget gate applied.
    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        if data.count > Self.maxPayloadBytes {
            // Encode a tooLarge stub instead of the offending payload, so
            // the receiver sees the budget failure rather than a
            // truncated stream.
            let stub = CardEnvelope.tooLarge(CardTooLarge(
                attemptedBytes: data.count,
                kindAttempted: self.kind
            ))
            return try encoder.encode(stub)
        }
        return data
    }
}

// MARK: - Renderable identity for SwiftUI Lists

extension CardEnvelope: Identifiable {
    /// Stable ID for SwiftUI rendering. Uses a content hash so consecutive
    /// renders of the same envelope don't churn the diff.
    public var id: String {
        var hasher = Hasher()
        hasher.combine(self)
        return "\(kind)#\(hasher.finalize())"
    }
}
