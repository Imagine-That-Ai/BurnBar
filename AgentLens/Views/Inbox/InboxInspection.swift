import Foundation
import OpenBurnBarKernel

// MARK: - Inbox inspection
//
// Everything in this file is pure: given a payload, it decides what a number
// means, how it should read, and what the user can reach from it. No SwiftUI,
// no I/O — so the whole "click a number, get the truth" contract is unit
// testable, and the views stay dumb.
//
// The daemon publishes metrics as `[String: String]` on purpose (schema-stable
// across detectors). That freedom is exactly why the presentation layer has to
// carry the vocabulary: `spend_usd` is a raw key, not a label, and `90.964` is
// a raw number, not money.

// MARK: - Drill-through targets

/// Where a number, an evidence row, or a breakdown line can take you.
///
/// `none` is a first-class case, not a failure: some citations genuinely have
/// nowhere to go, and the UI must say so out loud instead of rendering a dead
/// control that looks clickable.
enum InboxDrillTarget: Hashable, Sendable {
    case sessionLog(conversationID: String)
    case web(url: String)
    case reveal(path: String)
    case charts
    case none

    /// Verb shown *before* the click, so the outcome is never a surprise.
    var activationLabel: String? {
        switch self {
        case .sessionLog: return "Open session log"
        case .web: return "Open in browser"
        case .reveal: return "Show in Finder"
        case .charts: return "Open Charts"
        case .none: return nil
        }
    }

    var symbol: String {
        switch self {
        case .sessionLog: return "text.bubble"
        case .web: return "arrow.up.forward.square"
        case .reveal: return "folder"
        case .charts: return "chart.bar"
        case .none: return "minus"
        }
    }

    var isReachable: Bool { self != .none }
}

/// One line inside a metric's breakdown.
struct InboxDrillRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let target: InboxDrillTarget
    /// 0…1 share of the metric total, when the metric is additive (spend).
    /// Nil for counts, where a bar would imply a magnitude that does not exist.
    let share: Double?

    init(id: String, title: String, detail: String? = nil, target: InboxDrillTarget = .none, share: Double? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.target = target
        self.share = share
    }
}

// MARK: - Metric units

enum InboxMetricUnit: Hashable, Sendable {
    case count
    case currencyUSD
    /// A 0–1 fraction that should read as a percentage.
    case ratio
    /// Already expressed as 0–100.
    case percent
    case minutes
    case seconds
    case hours
    case days
    case milliseconds
    case tokens
    /// Not a number at all — render the string the daemon wrote.
    case text
}

// MARK: - One examinable metric

struct InboxMetric: Identifiable, Hashable, Sendable {
    /// Raw daemon key (`spend_usd`). Kept for accessibility ids and debugging.
    let key: String
    /// Human label (`Spend`). Never the raw key.
    let label: String
    /// Formatted for reading (`$90.96`). Never three decimals of money.
    let value: String
    /// The number behind the string, when there is one.
    let numericValue: Double?
    let unit: InboxMetricUnit
    /// What is being counted, over what window. Always present — a metric with
    /// no drill-through data still has to explain itself in words.
    let explanation: String
    /// Honest coverage note when the breakdown cannot show everything counted.
    let coverageNote: String?
    let rows: [InboxDrillRow]
    /// Where the whole metric goes, when it has a surface of its own.
    let target: InboxDrillTarget

    var id: String { key }

    /// True when clicking reveals rows rather than only prose.
    var hasBreakdown: Bool { rows.isEmpty == false }
}

// MARK: - Metric inspector

enum InboxMetricInspector {

    /// Keys that are prose, not statistics. They render elsewhere (the
    /// provenance footer) rather than as a stat.
    static let excludedKeys: Set<String> = ["calibration_note"]

    // MARK: Entry point

    /// Builds the full examinable metric set for an item.
    static func metrics(
        payload: BurnBarInboxItemPayload,
        summary: BurnBarInboxItemSummary
    ) -> [InboxMetric] {
        let raw = payload.metrics.filter { excludedKeys.contains($0.key) == false }
        let ordered = raw.keys.sorted { lhs, rhs in
            let lhsRank = displayRank(lhs)
            let rhsRank = displayRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs < rhs
        }

        return ordered.compactMap { key -> InboxMetric? in
            guard let rawValue = raw[key] else { return nil }
            let unit = unit(for: key, rawValue: rawValue)
            let number = Double(rawValue.trimmingCharacters(in: .whitespaces))
            let rows = drillRows(key: key, evidence: payload.evidence, summary: summary)
            return InboxMetric(
                key: key,
                label: humanizedLabel(for: key),
                value: formattedValue(key: key, rawValue: rawValue),
                numericValue: number,
                unit: unit,
                explanation: explanation(for: key, metrics: raw),
                coverageNote: coverageNote(key: key, number: number, rows: rows),
                rows: rows,
                target: target(for: key, unit: unit)
            )
        }
    }

    /// Money first, then the counts that describe scope, then everything else.
    /// A stable, meaningful order beats alphabetical — `Dirty workspaces` has no
    /// business leading a spend brief.
    static func displayRank(_ key: String) -> Int {
        switch unit(for: key, rawValue: "0") {
        case .currencyUSD: return 0
        case .minutes, .seconds, .hours, .days, .milliseconds: return 1
        case .ratio, .percent: return 2
        case .tokens: return 3
        case .count: return 4
        case .text: return 5
        }
    }

    // MARK: Units

    static func unit(for key: String, rawValue: String) -> InboxMetricUnit {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard Double(trimmed) != nil else { return .text }
        let lowered = key.lowercased()
        if lowered.hasSuffix("_usd") || lowered.hasSuffix("_cost") || lowered == "cost" || lowered == "spend" {
            return .currencyUSD
        }
        if lowered.hasSuffix("_rate") || lowered.hasSuffix("_ratio") || lowered.hasSuffix("_share") { return .ratio }
        if lowered.hasSuffix("_pct") || lowered.hasSuffix("_percent") { return .percent }
        if lowered.hasSuffix("_minutes") || lowered.hasSuffix("_mins") { return .minutes }
        if lowered.hasSuffix("_seconds") || lowered.hasSuffix("_secs") { return .seconds }
        if lowered.hasSuffix("_hours") { return .hours }
        if lowered.hasSuffix("_days") { return .days }
        if lowered.hasSuffix("_ms") { return .milliseconds }
        if lowered.hasSuffix("_tokens") || lowered == "tokens" { return .tokens }
        return .count
    }

    // MARK: Value formatting

    /// The fix for `$90.964`. Every unit gets a formatter that matches how a
    /// human writes that quantity — money to the cent, counts with separators,
    /// durations as spans, rates as percentages.
    static func formattedValue(key: String, rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(trimmed) else { return trimmed }
        return format(number, as: unit(for: key, rawValue: trimmed))
    }

    static func format(_ value: Double, as unit: InboxMetricUnit) -> String {
        guard value.isFinite else { return "—" }
        switch unit {
        case .currencyUSD:
            return currency(value)
        case .ratio:
            return percentage(value * 100)
        case .percent:
            return percentage(value)
        case .minutes:
            return duration(seconds: value * 60)
        case .seconds:
            return duration(seconds: value)
        case .hours:
            return duration(seconds: value * 3_600)
        case .days:
            return duration(seconds: value * 86_400)
        case .milliseconds:
            return value < 1_000
                ? "\(Int(value.rounded()))ms"
                : duration(seconds: value / 1_000)
        case .tokens:
            return compactCount(value)
        case .count:
            return groupedCount(value)
        case .text:
            return String(value)
        }
    }

    /// Money, always to the cent — except genuinely sub-cent amounts, where
    /// rounding to `$0.00` would erase a real charge.
    static func currency(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let magnitude = abs(value)
        let body: String
        if magnitude < 1e-9 {
            body = "$0.00"
        } else if magnitude < 0.01 {
            body = String(format: "$%.4f", magnitude)
        } else {
            let digits = Self.decimalFormatter.string(from: NSNumber(value: magnitude))
                ?? String(format: "%.2f", magnitude)
            body = "$" + digits
        }
        return value < 0 ? "-" + body : body
    }

    static func groupedCount(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == value.rounded(), abs(value) < 1e15 {
            return Self.integerFormatter.string(from: NSNumber(value: Int(value))) ?? String(Int(value))
        }
        return Self.decimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func compactCount(_ value: Double) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000_000 { return sign + trimZero(magnitude / 1_000_000_000) + "B" }
        if magnitude >= 1_000_000 { return sign + trimZero(magnitude / 1_000_000) + "M" }
        if magnitude >= 10_000 { return sign + trimZero(magnitude / 1_000) + "k" }
        return groupedCount(value)
    }

    /// Whole numbers at 10% and above, one decimal below — the same rule the
    /// rest of the app uses, so a percentage never reads differently here.
    static func percentage(_ percent: Double) -> String {
        guard percent.isFinite else { return "—" }
        let magnitude = abs(percent)
        if magnitude >= 10 || percent == percent.rounded() {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }

    /// Human spans: `45m`, `3h 12m`, `2d 5h`. Never `192 minutes`.
    static func duration(seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let total = Int(abs(seconds).rounded())
        let sign = seconds < 0 ? "-" : ""
        if total < 60 { return "\(sign)\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(sign)\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(sign)\(hours)h" : "\(sign)\(hours)h \(remainder)m"
        }
        let days = hours / 24
        let remainder = hours % 24
        return remainder == 0 ? "\(sign)\(days)d" : "\(sign)\(days)d \(remainder)h"
    }

    private static func trimZero(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    /// Locale-pinned so a French Mac and the test suite agree on `$1,234.50`.
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    // MARK: Labels

    /// Curated first, generic second. The curated table is where product voice
    /// lives (`spend_usd` is "Spend", not "Spend usd"); the generic path keeps a
    /// detector that ships tomorrow from rendering a raw key.
    static let curatedLabels: [String: String] = [
        "sessions": "Sessions",
        "with_messages": "With messages",
        "projects": "Projects",
        "dirty_workspaces": "Dirty workspaces",
        "spend_usd": "Spend",
        "wasted_minutes": "Wasted time",
        "waste_rate": "Wasted runs",
        "failure_rate": "Failure rate",
        "stale_days": "Idle for",
        "open_prs": "Open PRs",
        "runs": "Workflow runs"
    ]

    /// Tokens that only restate the unit the value already carries.
    private static let strippableUnitTokens: Set<String> = [
        "usd", "pct", "percent", "count", "ms", "minutes", "mins", "seconds", "secs", "hours", "days"
    ]

    private static let acronyms: Set<String> = [
        "ci", "cd", "pr", "prs", "api", "url", "id", "ids", "cpu", "gpu", "io", "sql",
        "ui", "ux", "ai", "llm", "usd", "http", "https", "mcp", "cli", "sdk", "os",
        "ram", "tls", "json", "yaml", "pii", "rpc", "db"
    ]

    static func humanizedLabel(for key: String) -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let curated = curatedLabels[normalized] { return curated }

        var words = normalized.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }).map(String.init)
        // Drop a trailing unit token only when something is left to name.
        if let last = words.last, strippableUnitTokens.contains(last), words.count > 1 {
            words.removeLast()
        }
        guard words.isEmpty == false else { return key }

        let rendered = words.enumerated().map { index, word -> String in
            if acronyms.contains(word) { return word.uppercased() }
            if index == 0 { return word.prefix(1).uppercased() + word.dropFirst() }
            return word
        }
        return rendered.joined(separator: " ")
    }

    // MARK: Explanations

    /// Every metric explains itself in words, whether or not it can show rows.
    static func explanation(for key: String, metrics: [String: String]) -> String {
        switch key {
        case "sessions":
            return """
                Every agent session the analyst found in the window this item covers — \
                including sessions the index has registered but not yet read.
                """
        case "with_messages":
            let total = metrics["sessions"].flatMap(Int.init)
            let substantive = metrics["with_messages"].flatMap(Int.init)
            if let total, let substantive, total >= substantive {
                let shells = total - substantive
                return """
                    Sessions with indexed messages. The other \(shells) of \(total) are empty shells — \
                    the index knows they exist but has not read their transcripts yet, so they count as \
                    activity, not as narrative.
                    """
            }
            return "Sessions that actually have indexed messages, as opposed to empty shells."
        case "projects":
            return """
                Distinct projects those sessions touched. A project is keyed on its name, falling back to \
                the workspace folder when a session carries no attribution.
                """
        case "dirty_workspaces":
            return """
                Git workspaces holding uncommitted changes at the moment the analyst looked. \
                Counted from the workspace scan, not from conversation text.
                """
        case "spend_usd":
            return """
                Model spend attributed to this window, summed over every project-and-model pair in the \
                evidence pack. This is measured from recorded usage, not estimated by a model.
                """
        case "wasted_minutes":
            return "Machine time spent on runs that produced no signal, summed across the window."
        default:
            return """
                \(humanizedLabel(for: key)) was measured by the deterministic detectors that run before any \
                model is asked for prose — it is arithmetic over the evidence pack, not a model's guess.
                """
        }
    }

    /// Says out loud when the breakdown cannot show everything the number counted.
    /// The daemon caps evidence at five citations per item, so `Sessions 16`
    /// legitimately lists fewer than sixteen rows — silence there would read as
    /// a bug or, worse, as a lie.
    static func coverageNote(key: String, number: Double?, rows: [InboxDrillRow]) -> String? {
        guard let number, number > 0 else { return nil }
        let counted = Int(number.rounded())
        guard rows.isEmpty == false else { return nil }
        guard rows.count < counted else { return nil }
        switch key {
        case "spend_usd":
            return "\(rows.count) of the contributing model/project pairs are itemized; the rest are folded into the total."
        default:
            return "\(rows.count) of \(counted) are cited here — items carry a capped set of citations."
        }
    }

    // MARK: Whole-metric target

    static func target(for key: String, unit: InboxMetricUnit) -> InboxDrillTarget {
        unit == .currencyUSD ? .charts : .none
    }

    // MARK: Breakdowns

    static func drillRows(
        key: String,
        evidence: [BurnBarInboxEvidence],
        summary: BurnBarInboxItemSummary
    ) -> [InboxDrillRow] {
        switch key {
        case "sessions":
            return evidence.filter { $0.kind == .conversation }.map(row(fromEvidence:))
        case "with_messages":
            return evidence
                .filter { $0.kind == .conversation && (messageCount(fromDetail: $0.detail) ?? 0) > 0 }
                .map(row(fromEvidence:))
        case "dirty_workspaces":
            return evidence
                .filter { $0.id.hasPrefix(Self.workspacePrefix) }
                .map(row(fromEvidence:))
        case "spend_usd":
            return spendRows(evidence: evidence)
        case "projects":
            return projectRows(evidence: evidence, summary: summary)
        default:
            return []
        }
    }

    static let workspacePrefix = "workspace:"

    private static func row(fromEvidence evidence: BurnBarInboxEvidence) -> InboxDrillRow {
        InboxDrillRow(
            id: evidence.id,
            title: evidence.label,
            detail: evidence.detail,
            target: InboxEvidenceInspector.target(for: evidence)
        )
    }

    /// Spend rows carry a share so the breakdown can rank visually — the single
    /// case where a bar is honest, because the parts genuinely sum to the whole.
    static func spendRows(evidence: [BurnBarInboxEvidence]) -> [InboxDrillRow] {
        let usage = evidence.filter { $0.kind == .usage }
        let costs = usage.map { cost(fromDetail: $0.detail) }
        let total = costs.compactMap { $0 }.reduce(0, +)
        let pairs = zip(usage, costs).sorted { lhs, rhs in
            (lhs.1 ?? 0) > (rhs.1 ?? 0)
        }
        return pairs.map { evidence, amount in
            InboxDrillRow(
                id: evidence.id,
                title: evidence.label,
                detail: evidence.detail,
                target: .charts,
                share: (total > 0 && amount != nil) ? min(1, max(0, (amount ?? 0) / total)) : nil
            )
        }
    }

    /// Projects are counted from session attribution the evidence pack does not
    /// itemize directly, so this names every project it *can* name — usage
    /// aggregates, dirty workspaces, and the item's own attribution — and the
    /// coverage note admits the gap rather than inventing rows.
    static func projectRows(
        evidence: [BurnBarInboxEvidence],
        summary: BurnBarInboxItemSummary
    ) -> [InboxDrillRow] {
        var seen = Set<String>()
        var rows: [InboxDrillRow] = []

        func append(_ name: String, detail: String, target: InboxDrillTarget) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, trimmed != "unattributed" else { return }
            guard seen.insert(trimmed.lowercased()).inserted else { return }
            rows.append(InboxDrillRow(id: "project:\(trimmed)", title: trimmed, detail: detail, target: target))
        }

        if let project = summary.projectName {
            append(project, detail: "this item's project", target: .none)
        }
        for entry in evidence where entry.kind == .usage {
            if let project = projectName(fromUsageLabel: entry.label) {
                append(project, detail: "named by recorded spend", target: .charts)
            }
        }
        for entry in evidence where entry.id.hasPrefix(workspacePrefix) {
            let path = String(entry.id.dropFirst(workspacePrefix.count))
            let folder = (path as NSString).lastPathComponent
            append(folder, detail: "workspace on disk", target: .reveal(path: path))
        }
        return rows
    }

    // MARK: Detail parsing
    //
    // The daemon writes these detail strings; parsing them is how the app
    // derives structure without asking for a schema change on a database a
    // shipped daemon also writes. Every parser returns nil rather than guessing.

    /// `"Claude Code · 341 messages"` → `341`.
    static func messageCount(fromDetail detail: String?) -> Int? {
        guard let detail else { return nil }
        if detail.localizedCaseInsensitiveContains("empty shell") { return 0 }
        let tokens = detail
            .split(whereSeparator: { $0 == " " || $0 == "\u{00B7}" || $0 == "\n" })
            .map(String.init)
        for (index, token) in tokens.enumerated() where token.hasPrefix("message") {
            guard index > 0 else { continue }
            if let number = Int(tokens[index - 1]) { return number }
        }
        return nil
    }

    /// `"12 calls · $4.20"` → `4.20`. Tolerates grouped thousands.
    static func cost(fromDetail detail: String?) -> Double? {
        guard let detail, let dollarIndex = detail.firstIndex(of: "$") else { return nil }
        var digits = ""
        for character in detail[detail.index(after: dollarIndex)...] {
            if character.isNumber || character == "." {
                digits.append(character)
            } else if character == "," {
                continue
            } else {
                break
            }
        }
        return Double(digits)
    }

    /// `"gpt-5.6-luna in BurnBar"` → `"BurnBar"`.
    static func projectName(fromUsageLabel label: String) -> String? {
        guard let range = label.range(of: " in ", options: .backwards) else { return nil }
        let candidate = String(label[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }
}

// MARK: - Evidence inspector

enum InboxEvidenceInspector {

    static let sessionURLPrefix = "openburnbar://sessions/"

    /// Resolves what a citation actually opens.
    ///
    /// Two categories were previously dead in the UI and are now reachable:
    /// workspace citations (no url, but the evidence id carries the real path)
    /// and usage citations (no url, but spend has a home on the Charts surface).
    static func target(for evidence: BurnBarInboxEvidence) -> InboxDrillTarget {
        if let raw = evidence.url?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false {
            if raw.hasPrefix(sessionURLPrefix) {
                let conversationID = String(raw.dropFirst(sessionURLPrefix.count))
                if conversationID.isEmpty == false { return .sessionLog(conversationID: conversationID) }
            }
            if let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" {
                return .web(url: raw)
            }
        }
        if evidence.id.hasPrefix(InboxMetricInspector.workspacePrefix) {
            let path = String(evidence.id.dropFirst(InboxMetricInspector.workspacePrefix.count))
            if path.isEmpty == false { return .reveal(path: path) }
        }
        if evidence.kind == .usage { return .charts }
        return .none
    }

    /// Why a row is inert, said plainly. An unexplained dead row is the bug the
    /// owner is complaining about; an explained one is a design decision.
    static func inertReason(for evidence: BurnBarInboxEvidence) -> String {
        switch evidence.kind {
        case .metric:
            return "A measured number, not a place — the figure itself is the citation."
        case .commit:
            return "Cited by hash. No remote link was recorded for this commit."
        default:
            return "Reference only — the analyst cited this, but recorded nowhere to open."
        }
    }

    /// Copyable identity for the row's context menu.
    static func referenceID(for evidence: BurnBarInboxEvidence) -> String { evidence.id }

    /// Whether the label needs a way to see the rest of it.
    static func isTruncationLikely(_ text: String, limit: Int = 58) -> Bool {
        text.count > limit
    }
}

// MARK: - Action inspector

/// What an action will do, whether it can do it, and whether it deserves a
/// warning — decided once, in one place, so the button and its accessibility
/// label can never disagree.
struct InboxActionReadiness: Hashable, Sendable {
    let isEnabled: Bool
    /// Present only when disabled; explains rather than hides.
    let disabledReason: String?
    /// Plain-language outcome, shown before activation.
    let effect: String
    /// True when the control writes to the pasteboard and nothing else.
    let isCopyOnly: Bool
    /// Present when the payload reads as destructive.
    let caution: String?
}

enum InboxActionInspector {

    static func readiness(
        for action: BurnBarInboxAction,
        settingsAvailable: Bool,
        pathExists: (String) -> Bool
    ) -> InboxActionReadiness {
        let value = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action.kind {
        case .openURL:
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                return InboxActionReadiness(
                    isEnabled: false,
                    disabledReason: "This is not a web address the app can open: \(value.isEmpty ? "no link" : value)",
                    effect: "Would open a link in your browser.",
                    isCopyOnly: false,
                    caution: nil
                )
            }
            let host = url.host ?? value
            return InboxActionReadiness(
                isEnabled: true,
                disabledReason: nil,
                effect: "Opens \(host) in your default browser.",
                isCopyOnly: false,
                caution: nil
            )

        case .resumeConversation, .openSessionLog:
            guard value.isEmpty == false else {
                return InboxActionReadiness(
                    isEnabled: false,
                    disabledReason: "No conversation was recorded for this action.",
                    effect: "Would open the session log.",
                    isCopyOnly: false,
                    caution: nil
                )
            }
            return InboxActionReadiness(
                isEnabled: true,
                disabledReason: nil,
                effect: "Opens the session log and scrolls to the passage behind this item.",
                isCopyOnly: false,
                caution: nil
            )

        case .openProject:
            guard value.isEmpty == false else {
                return InboxActionReadiness(
                    isEnabled: false,
                    disabledReason: "No folder was recorded for this action.",
                    effect: "Would reveal the project folder.",
                    isCopyOnly: false,
                    caution: nil
                )
            }
            guard pathExists(expandedPath(value)) else {
                return InboxActionReadiness(
                    isEnabled: false,
                    disabledReason: "That folder is no longer on disk: \(value)",
                    effect: "Would reveal the project folder in Finder.",
                    isCopyOnly: false,
                    caution: nil
                )
            }
            return InboxActionReadiness(
                isEnabled: true,
                disabledReason: nil,
                effect: "Reveals \((value as NSString).lastPathComponent) in Finder.",
                isCopyOnly: false,
                caution: nil
            )

        case .openSettings:
            guard settingsAvailable else {
                return InboxActionReadiness(
                    isEnabled: false,
                    disabledReason: "Settings cannot be opened from this window.",
                    effect: "Would open AI Inbox settings.",
                    isCopyOnly: false,
                    caution: nil
                )
            }
            return InboxActionReadiness(
                isEnabled: true,
                disabledReason: nil,
                effect: "Opens AI Inbox settings.",
                isCopyOnly: false,
                caution: nil
            )

        case .runCommand:
            guard value.isEmpty == false else {
                return InboxActionReadiness(
                    isEnabled: false,
                    disabledReason: "No command was recorded for this action.",
                    effect: "Would copy a command to the clipboard.",
                    isCopyOnly: true,
                    caution: nil
                )
            }
            return InboxActionReadiness(
                isEnabled: true,
                disabledReason: nil,
                // The single most important sentence in this file: the app never
                // executes a suggested command, and the control must say so
                // before it is pressed, not after.
                effect: "Copies this command to your clipboard. Nothing runs.",
                isCopyOnly: true,
                caution: looksDestructive(value)
                    ? "This command changes or removes things. Read it before you run it yourself."
                    : nil
            )
        }
    }

    /// Substrings that mean "this rewrites or deletes state". Deliberately
    /// broad: a false caution costs a line of text, a missed one costs work.
    static let destructiveSignatures = [
        "rm -rf", "rm -r", "rm -f", "git reset --hard", "git clean -f", "git checkout --",
        "push --force", "push -f", "force-with-lease", "kill -9", "pkill", "killall",
        "drop table", "drop database", "truncate", "dd if=", "mkfs", "shutdown", "reboot",
        "sudo ", "chmod -r", "chown -r", "> /dev/"
    ]

    static func looksDestructive(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return destructiveSignatures.contains { lowered.contains($0) }
    }

    static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Exactly one primary. When the daemon marks several (or none), the first
    /// reachable action leads — an "obvious primary" that is sometimes three
    /// buttons is not obvious.
    static func partition(
        _ actions: [BurnBarInboxAction]
    ) -> (primary: BurnBarInboxAction?, secondary: [BurnBarInboxAction]) {
        guard actions.isEmpty == false else { return (nil, []) }
        let primary = actions.first(where: \.isPrimary) ?? actions.first
        let secondary = actions.filter { $0.id != primary?.id }
        return (primary, secondary)
    }
}

// MARK: - Occurrence inspector

/// The story behind "seen 161 times": when it started, when it last fired, and
/// how often — so a recurrence count is a fact you can check rather than a
/// number you have to take on faith.
struct InboxOccurrenceSummary: Hashable, Sendable {
    let count: Int
    let firstSeen: Date
    let lastSeen: Date
    /// e.g. "about 7 times an hour".
    let cadence: String?
    /// Plain-language span, e.g. "22 hours".
    let span: String
    let explanation: String
}

enum InboxOccurrenceInspector {

    static func summarize(summary: BurnBarInboxItemSummary) -> InboxOccurrenceSummary {
        // `lastSeenAt` can precede `firstSeenAt` in a clock-skewed or
        // hand-edited row; clamp so a span never renders negative.
        let lastSeen = max(summary.lastSeenAt, summary.firstSeenAt)
        let interval = max(0, lastSeen.timeIntervalSince(summary.firstSeenAt))
        let span = InboxMetricInspector.duration(seconds: interval)
        return InboxOccurrenceSummary(
            count: summary.occurrenceCount,
            firstSeen: summary.firstSeenAt,
            lastSeen: lastSeen,
            cadence: cadence(count: summary.occurrenceCount, interval: interval),
            span: span,
            explanation: """
                The analyst re-derived this same condition \(summary.occurrenceCount) \
                time\(summary.occurrenceCount == 1 ? "" : "s"). It stays one item rather than \
                \(summary.occurrenceCount) copies — the count is how persistent it is, not how noisy the inbox is.
                """
        )
    }

    /// Nil below two occurrences or under a minute of span: a rate computed
    /// from one data point is decoration, not information.
    static func cadence(count: Int, interval: TimeInterval) -> String? {
        guard count > 1, interval >= 60 else { return nil }
        let perHour = Double(count) / (interval / 3_600)
        if perHour >= 1 {
            return "about \(InboxMetricInspector.groupedCount(perHour.rounded())) times an hour"
        }
        let perDay = perHour * 24
        if perDay >= 1 {
            return "about \(InboxMetricInspector.groupedCount(perDay.rounded())) times a day"
        }
        return "less than once a day"
    }

    static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Accessibility identifiers

/// Inbox-owned identifiers. Declared here rather than in the shared
/// `OBBAccessibilityID` file so this work stays inside `Views/Inbox`.
extension OBBAccessibilityID {
    static func inboxMetric(_ key: String) -> String { "inbox.metric.\(inboxSlug(key))" }
    static func inboxMetricRow(_ id: String) -> String { "inbox.metric.row.\(inboxSlug(id))" }
    static func inboxEvidence(_ id: String) -> String { "inbox.evidence.\(inboxSlug(id))" }
    static func inboxAction(_ id: String) -> String { "inbox.action.\(inboxSlug(id))" }
    static let inboxOccurrence = "inbox.occurrence"

    private static func inboxSlug(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .lowercased()
    }
}
