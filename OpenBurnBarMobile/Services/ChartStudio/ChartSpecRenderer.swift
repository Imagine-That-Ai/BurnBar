import Foundation

// MARK: - Chart Studio Rendering
//
// `ChartStudioRendering` is the typed value Chart Studio renders on the
// canvas. It is decoded from the JSON Hermes returns. The schema is
// intentionally narrow so the renderer cannot be tricked into running
// arbitrary code — `mermaid` content is sanitized before being injected
// into the WebView and `swift_chart` specs reference only the digest's
// own column names.

public enum ChartStudioRendering: Hashable, Sendable {
    case insight(InsightSpec)
    case mermaid(MermaidSpec)
    case swiftChart(ChartSpec)
    case composed([ChartStudioRendering])
    case error(String)
}

// MARK: - Insight

public struct InsightSpec: Codable, Hashable, Sendable {
    public let title: String
    public let body: String
    public let sparkline: [Double]?
    public let tone: String?         // "positive" | "neutral" | "warning"

    public init(title: String, body: String, sparkline: [Double]? = nil, tone: String? = nil) {
        self.title = title
        self.body = body
        self.sparkline = sparkline
        self.tone = tone
    }
}

// MARK: - Mermaid

public struct MermaidSpec: Codable, Hashable, Sendable {
    public let title: String?
    public let source: String        // Mermaid DSL — sanitized before render

    public init(title: String? = nil, source: String) {
        self.title = title
        self.source = source
    }
}

// MARK: - Swift Chart Spec

public struct ChartSpec: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, Hashable, Sendable {
        case line
        case bar
        case stackedBar = "stacked_bar"
        case area
        case stackedArea = "stacked_area"
        case stream
        case scatter
        case heatmap
        case donut
        case rule
    }

    public struct Series: Codable, Hashable, Sendable {
        public let name: String
        public let color: String?         // optional hex (#RRGGBB) — clamped to palette
        public let points: [DataPoint]
    }

    public struct DataPoint: Codable, Hashable, Sendable {
        public let x: AnyValue
        public let y: Double
        public let group: String?
        public let label: String?
    }

    public struct AxisDescriptor: Codable, Hashable, Sendable {
        public let title: String?
        public let kind: String?          // "linear" | "time" | "category"
    }

    public struct Annotation: Codable, Hashable, Sendable {
        public let kind: String           // "ruleX" | "ruleY" | "text"
        public let x: AnyValue?
        public let y: Double?
        public let label: String?
    }

    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let xAxis: AxisDescriptor?
    public let yAxis: AxisDescriptor?
    public let series: [Series]
    public let annotations: [Annotation]?
    public let valueFormat: String?       // "currency" | "tokens" | "raw" | "percent"
}

// MARK: - Generic value bag

/// Carries an `x` value that can be a date, number, or string. We keep it
/// untyped at the JSON layer and let the renderer interpret based on the
/// chart kind / axis descriptor.
public enum AnyValue: Codable, Hashable, Sendable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let v = try? c.decode(Bool.self) {
            self = .bool(v)
            return
        }
        if let v = try? c.decode(Int.self) {
            self = .int(v)
            return
        }
        if let v = try? c.decode(Double.self) {
            self = .double(v)
            return
        }
        if let v = try? c.decode(String.self) {
            self = .string(v)
            return
        }
        throw DecodingError.typeMismatch(
            AnyValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported AnyValue")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .double(let d): try c.encode(d)
        case .int(let i):    try c.encode(i)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        }
    }

    public var asString: String? {
        switch self {
        case .string(let s): return s
        case .double(let d): return String(d)
        case .int(let i):    return String(i)
        case .bool(let b):   return String(b)
        case .null:          return nil
        }
    }

    public var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        case .string(let s): return Double(s)
        default:             return nil
        }
    }

    public var asDate: Date? {
        if case .string(let s) = self {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            for fmt in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM-dd HH:mm:ss"] {
                f.dateFormat = fmt
                if let d = f.date(from: s) { return d }
            }
        }
        return nil
    }
}

// MARK: - Renderer

public enum ChartSpecRenderer {

    /// Decode a JSON string (as produced by Hermes) into a typed rendering.
    /// This is forgiving — if the model wraps JSON in prose (e.g. ```json …```),
    /// we extract the first `{...}` block. If decoding fails entirely we
    /// surface an `.error` rendering rather than crashing the canvas.
    public static func decode(_ raw: String) -> ChartStudioRendering {
        let trimmed = extractFirstJSONObject(raw)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return .error("Hermes returned empty content.")
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return envelope.toRendering()
        } catch {
            // Try a more lenient pass — some models forget the `kind` wrapper.
            if let lenient = decodeBareSpec(data: data) {
                return lenient
            }
            return .error("Couldn't parse Hermes response: \(error.localizedDescription)")
        }
    }

    /// Sanitize a Mermaid source string before injection into WKWebView.
    /// Removes any HTML, JS pseudo-protocols, or `<script>` tags that a
    /// hostile model could try to embed.
    public static func sanitizeMermaid(_ source: String) -> String {
        var s = source
        // Strip code-fence wrappers if present.
        s = s.replacingOccurrences(of: "```mermaid", with: "")
        s = s.replacingOccurrences(of: "```", with: "")
        // Drop anything that looks like raw HTML or script tags.
        let bannedPatterns = [
            "(?i)<\\s*script[^>]*>[\\s\\S]*?<\\s*/\\s*script\\s*>",
            "(?i)<\\s*iframe[^>]*>[\\s\\S]*?<\\s*/\\s*iframe\\s*>",
            "(?i)javascript:",
            "(?i)data:[^,]*",
            "(?i)on[a-z]+\\s*=\\s*\"[^\"]*\"",
            "(?i)on[a-z]+\\s*=\\s*'[^']*'"
        ]
        for pattern in bannedPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    /// Walks the raw string to find the first top-level `{...}` substring.
    /// Handles common Hermes responses that prefix prose / code fences.
    static func extractFirstJSONObject(_ raw: String) -> String {
        guard let firstBrace = raw.firstIndex(of: "{") else { return "" }
        var depth = 0
        var endIndex = raw.endIndex
        var inString = false
        var escape = false
        var i = firstBrace
        while i < raw.endIndex {
            let ch = raw[i]
            if escape {
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = raw.index(after: i)
                        break
                    }
                }
            }
            i = raw.index(after: i)
        }
        return String(raw[firstBrace..<endIndex])
    }

    private static func decodeBareSpec(data: Data) -> ChartStudioRendering? {
        // Accept a bare ChartSpec (model forgot the wrapper).
        if let bare = try? JSONDecoder().decode(ChartSpec.self, from: data) {
            return .swiftChart(bare)
        }
        // Accept a bare Mermaid source string keyed by "mermaid".
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let mermaidSource = dict["mermaid"] as? String {
                return .mermaid(MermaidSpec(title: dict["title"] as? String, source: sanitizeMermaid(mermaidSource)))
            }
            if let body = dict["insight"] as? String {
                return .insight(InsightSpec(
                    title: dict["title"] as? String ?? "Insight",
                    body: body,
                    sparkline: dict["sparkline"] as? [Double],
                    tone: dict["tone"] as? String
                ))
            }
        }
        return nil
    }

    // MARK: - Wire envelope

    /// Top-level wire format the prompt asks Hermes to use.
    /// ```json
    /// { "kind": "swift_chart" | "mermaid" | "insight" | "composed",
    ///   "title": "…",
    ///   "swift_chart": ChartSpec,
    ///   "mermaid": MermaidSpec,
    ///   "insight": InsightSpec,
    ///   "components": [Envelope] }
    /// ```
    fileprivate struct Envelope: Codable {
        let kind: String
        let title: String?
        let swift_chart: ChartSpec?
        let mermaid: MermaidSpec?
        let insight: InsightSpec?
        let components: [Envelope]?

        func toRendering() -> ChartStudioRendering {
            switch kind.lowercased() {
            case "swift_chart", "chart", "native":
                if let chart = swift_chart {
                    return .swiftChart(chart)
                }
                return .error("Missing swift_chart payload.")
            case "mermaid", "diagram":
                if let m = mermaid {
                    return .mermaid(MermaidSpec(title: m.title ?? title, source: ChartSpecRenderer.sanitizeMermaid(m.source)))
                }
                return .error("Missing mermaid payload.")
            case "insight", "narrative":
                if let i = insight {
                    return .insight(i)
                }
                return .error("Missing insight payload.")
            case "composed", "stack":
                let items = (components ?? []).map { $0.toRendering() }
                return items.isEmpty ? .error("Composed payload had no components.") : .composed(items)
            case "error":
                return .error(insight?.body ?? title ?? "Hermes returned an error.")
            default:
                return .error("Unknown render kind: \(kind)")
            }
        }
    }
}
