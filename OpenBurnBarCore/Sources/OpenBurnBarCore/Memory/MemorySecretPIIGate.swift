// SPDX-License-Identifier: AGPL-3.0-only
//
// MemorySecretPIIGate — the shared, fail-closed pre-persistence secret/PII gate.
//
// This is the single security spine for every memory-write path in the product
// (chat-memory authority writes in the macOS/iOS app, and the daemon's
// project-code `remember` path). It was promoted out of the daemon's private
// `ProjectCodeSecretScanner` so the app scanner and the daemon scanner can no
// longer drift: both now delegate here.
//
// Design contract (see 2026-06-19-memory-activation-integrated-build-plan PR-C1):
//   * Public, `Sendable`, stateless value type. Safe to call from any actor.
//   * Three verdicts: `.allow`, `.redact(text, findings)`, `.reject(findings)`.
//   * Fail-closed: a missing or corrupt corpus makes EVERY evaluation reject
//     with a synthetic `corpus-unavailable` finding. The gate never silently
//     degrades to "allow".
//   * Findings carry BOTH a stable dashed `id` (e.g. `openai-api-key`) and a
//     human `label` (e.g. "OpenAI API key detected") plus a `kind`
//     (`.secret` / `.pii`). The daemon path emits `.map(\.label)` (its audit
//     contract); the chat path emits `.map(\.id)` (its migration contract).
//   * Credit-card matches MUST pass the Luhn checksum and IPv4 matches MUST have
//     every octet in 0...255 — otherwise the loose corpus regexes would silently
//     delete legitimate memories (version strings, order IDs, phone numbers) and
//     that is a data-integrity regression, not a security win.
//   * Redaction is bounded: it re-gates the redacted text until `.allow` or a
//     bounded pass cap, and downgrades `redact -> reject` the instant ANY finding
//     (entropy or decoded-view) cannot be located on the original text. You can
//     never redact what you cannot point at.

import CryptoKit
import Foundation

// MARK: - Public surface

/// Whether a gate finding represents a credential/secret or personally
/// identifiable information. Callers can use this to apply policy per category.
public enum MemoryGateFindingKind: String, Sendable, Codable, Equatable, CaseIterable {
    case secret
    case pii
}

/// A single thing the gate found in the scanned text.
///
/// Carries both a stable machine `id` (dashed, e.g. `openai-api-key`) and a
/// human-readable `label`. The two finding-emitting call sites disagree on which
/// they want — chat persistence keys off `id`, daemon audit keys off `label` —
/// so the gate carries both and lets each site project the one it needs.
public struct MemoryGateFinding: Sendable, Equatable, Codable {
    public let id: String
    public let label: String
    public let kind: MemoryGateFindingKind

    public init(id: String, label: String, kind: MemoryGateFindingKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

/// What the gate should do when it finds something. `.allow` is never a policy —
/// it is only ever a *verdict* reached when nothing was found.
public enum MemoryGatePolicy: Sendable, Equatable {
    /// Refuse the whole write if anything is found (fail-closed; the default).
    case reject
    /// Attempt to redact located spans, re-gating until clean or a bounded cap;
    /// downgrades to `.reject` if any finding cannot be located on the original
    /// text.
    case redact
}

/// The gate's decision.
public enum MemoryGateVerdict: Sendable, Equatable {
    /// Nothing matched. The text is safe to persist verbatim.
    case allow
    /// Findings matched but all were locatable and redacted. `text` is the
    /// redacted body safe to persist; `findings` describes what was removed.
    case redact(text: String, findings: [MemoryGateFinding])
    /// The write must be refused. `findings` describes why.
    case reject(findings: [MemoryGateFinding])

    /// The findings carried by this verdict (empty for `.allow`).
    public var findings: [MemoryGateFinding] {
        switch self {
        case .allow: []
        case .redact(_, let findings): findings
        case .reject(let findings): findings
        }
    }
}

/// The shared secret/PII gate. Stateless façade over a process-wide, lazily
/// loaded, immutable corpus.
public enum MemorySecretPIIGate {
    // MARK: Synthetic finding identifiers

    /// Emitted (as the sole finding) when the corpus is missing or corrupt so the
    /// gate fails closed instead of silently allowing.
    public static let corpusUnavailableFindingID = "secret-scanner-corpus-unavailable"
    /// The label string the daemon historically used for an unavailable corpus.
    /// Preserved verbatim so existing audit semantics do not shift.
    public static let corpusUnavailableLabel = "Secret scanner corpus unavailable"
    /// Stable id for high-entropy token findings (the corpus entropy block has no
    /// per-pattern id of its own).
    public static let highEntropyFindingID = "high-entropy-token"

    /// Maximum number of redaction passes before the gate fails closed. Bounds the
    /// re-gate loop so a pathological input cannot spin.
    static let maxRedactionPasses = 8

    // MARK: Availability

    /// `true` when the corpus loaded and compiled cleanly. When `false`, every
    /// `evaluate`/`findings` call fails closed. Exposed so callers (and tests, in
    /// particular the daemon executable test target where `Bundle.module`
    /// synthesis is a stated risk) can assert the gate is live.
    public static var isAvailable: Bool { corpus.available }

    /// The loaded corpus version string (empty when unavailable). Diagnostic only.
    public static var corpusVersion: String { corpus.version }

    // MARK: Primary API

    /// Scan `text` and return the gate's decision under `policy`.
    ///
    /// - Parameters:
    ///   - text: the untrusted candidate memory body.
    ///   - policy: `.reject` (default, fail-closed) or `.redact`.
    public static func evaluate(_ text: String, policy: MemoryGatePolicy = .reject) -> MemoryGateVerdict {
        guard corpus.available else {
            return .reject(findings: [unavailableFinding])
        }

        let scan = scanFindings(in: text)
        guard scan.isEmpty == false else { return .allow }

        switch policy {
        case .reject:
            return .reject(findings: dedupedPublicFindings(scan))
        case .redact:
            return redactEvaluate(originalText: text, initialScan: scan)
        }
    }

    /// Convenience: the deduped findings for `text` without applying a policy.
    /// Returns the fail-closed `corpus-unavailable` finding when the corpus could
    /// not be loaded.
    public static func findings(in text: String) -> [MemoryGateFinding] {
        guard corpus.available else { return [unavailableFinding] }
        return dedupedPublicFindings(scanFindings(in: text))
    }

    /// Back-compat shim for the daemon's existing label-only contract.
    /// Equivalent to `findings(in:).map(\.label)` (deduped, order-preserving).
    public static func labels(in text: String) -> [String] {
        guard corpus.available else { return [corpusUnavailableLabel] }
        var seen = Set<String>()
        var labels: [String] = []
        for finding in scanFindings(in: text) where seen.insert(finding.label).inserted {
            labels.append(finding.label)
        }
        return labels
    }

    /// Back-compat shim for the chat path's id contract.
    /// Equivalent to `findings(in:).map(\.id)` (deduped, order-preserving).
    public static func findingIDs(in text: String) -> [String] {
        guard corpus.available else { return [corpusUnavailableFindingID] }
        var seen = Set<String>()
        var ids: [String] = []
        for finding in scanFindings(in: text) where seen.insert(finding.id).inserted {
            ids.append(finding.id)
        }
        return ids
    }

    // MARK: - Testing seam
    //
    // `_evaluate(_:policy:overrideCorpus:)` is the ONLY test seam in this type.
    // It re-runs the corpus availability guard against a caller-supplied corpus,
    // enabling tests to inject `LoadedCorpus.unavailable` and prove the
    // fail-closed branch without altering any production code paths.
    //
    // IMPORTANT: Do NOT call this from production code. It is intentionally
    // `internal` (not `private`) so `@testable import` can reach it.
    static func _evaluate(
        _ text: String,
        policy: MemoryGatePolicy = .reject,
        overrideCorpus: LoadedCorpus
    ) -> MemoryGateVerdict {
        guard overrideCorpus.available else {
            // Corpus unavailable — fail closed. This is the exact guard mirrored
            // from the public `evaluate` path; both must agree.
            return .reject(findings: [unavailableFinding])
        }
        // Corpus is available: delegate to the normal evaluation so the seam
        // exercises the real scanner for the positive (available) case too.
        return evaluate(text, policy: policy)
    }

    // MARK: - Redaction (bounded, fail-closed)

    private static func redactEvaluate(originalText: String, initialScan: [ScanFinding]) -> MemoryGateVerdict {
        // A finding without a locatable span on the *current* text cannot be
        // excised. Redacting around it would persist the very secret/PII we
        // detected, so the only safe move is to refuse the whole write.
        if initialScan.contains(where: { $0.range == nil }) {
            return .reject(findings: dedupedPublicFindings(initialScan))
        }

        var working = originalText
        var accumulated: [ScanFinding] = initialScan
        var pass = 0

        while pass < maxRedactionPasses {
            let scan = pass == 0 ? initialScan : scanFindings(in: working)
            if scan.isEmpty {
                return .redact(text: working, findings: dedupedPublicFindings(accumulated))
            }
            // Any newly-surfaced non-locatable finding (e.g. an entropy token that
            // only appears after an earlier redaction reshaped the text) downgrades
            // to reject — fail closed.
            if scan.contains(where: { $0.range == nil }) {
                return .reject(findings: dedupedPublicFindings(accumulated + scan))
            }
            accumulated.append(contentsOf: scan)
            working = applyRedactions(scan, to: working)
            pass += 1
        }

        // Cap exhausted while findings remain: fail closed rather than ship a body
        // we could not fully clean.
        let residual = scanFindings(in: working)
        if residual.isEmpty {
            return .redact(text: working, findings: dedupedPublicFindings(accumulated))
        }
        return .reject(findings: dedupedPublicFindings(accumulated + residual))
    }

    /// Replace every located span with a kind-tagged placeholder.
    ///
    /// `ScanFinding.range` indexes the ORIGINAL text. Swift `String` does not
    /// guarantee index stability across mutation, so we convert each span to
    /// character offsets up front, sort right-to-left, and recompute fresh indices
    /// on the working copy before each replacement. Applying from the end means a
    /// replacement never shifts the offsets of spans that are still pending (they
    /// are all at lower offsets), so the recomputed indices stay correct.
    private static func applyRedactions(_ findings: [ScanFinding], to text: String) -> String {
        let offsets: [(lower: Int, upper: Int, kind: MemoryGateFindingKind)] = findings
            .compactMap { finding in
                guard let range = finding.range else { return nil }
                let lower = text.distance(from: text.startIndex, to: range.lowerBound)
                let upper = text.distance(from: text.startIndex, to: range.upperBound)
                return (lower, upper, finding.kind)
            }
            .sorted { $0.lower > $1.lower }

        var result = text
        var lastAppliedLower = Int.max
        for span in offsets {
            // Skip a span that overlaps an already-applied (higher) redaction.
            guard span.upper <= lastAppliedLower else { continue }
            guard span.lower >= 0, span.upper <= result.count, span.lower < span.upper else { continue }
            let lowerIndex = result.index(result.startIndex, offsetBy: span.lower)
            let upperIndex = result.index(result.startIndex, offsetBy: span.upper)
            result.replaceSubrange(lowerIndex..<upperIndex, with: placeholder(for: span.kind))
            lastAppliedLower = span.lower
        }
        return result
    }

    private static func placeholder(for kind: MemoryGateFindingKind) -> String {
        switch kind {
        case .secret: "[REDACTED-SECRET]"
        case .pii: "[REDACTED-PII]"
        }
    }

    // MARK: - Scanning

    /// Internal finding with an optional span on the ORIGINAL text. `range == nil`
    /// means the finding surfaced only via a derived/decoded view and cannot be
    /// located in the body the caller would persist.
    struct ScanFinding {
        let id: String
        let label: String
        let kind: MemoryGateFindingKind
        let range: Range<String.Index>?
    }

    /// Run every compiled pattern + entropy heuristic over the original text and
    /// its derived views, returning findings with original-text spans where
    /// possible.
    ///
    /// Per-view rule (preserved from the daemon engine this was promoted from):
    /// entropy is only evaluated for a view when NO explicit corpus pattern
    /// matched that view. An explicit, named secret is strictly more informative
    /// than "high entropy token", and surfacing both for the same span would be
    /// noise — and, critically, would break the chat audit contract that asserts a
    /// single named finding. The redaction loop in `redactEvaluate` is what
    /// re-surfaces a previously-suppressed entropy token after the named secret is
    /// excised, so suppression here does not weaken redaction completeness.
    private static func scanFindings(in text: String) -> [ScanFinding] {
        var findings: [ScanFinding] = []

        // View 0: the original text — findings are locatable (carry spans).
        findings.append(contentsOf: scanView(text, locatable: true))

        // Derived views (line-continuation joins, joined string literals,
        // base64/hex-decoded payloads). Real but NOT locatable on the original
        // body, so spans are nil — which forces a redact->reject downgrade.
        for view in derivedViews(for: text) {
            findings.append(contentsOf: scanView(view, locatable: false))
        }

        return findings
    }

    /// Scan a single view. Explicit pattern matches suppress entropy for this
    /// view. When `locatable`, original-text spans are attached to each finding;
    /// otherwise spans are nil.
    private static func scanView(_ view: String, locatable: Bool) -> [ScanFinding] {
        let nsView = view as NSString
        let fullRange = NSRange(location: 0, length: nsView.length)
        var results: [ScanFinding] = []
        var matchedExplicitPattern = false

        for pattern in corpus.patterns {
            for match in pattern.regex.matches(in: view, range: fullRange) {
                guard let swiftRange = Range(match.range, in: view) else { continue }
                let matched = String(view[swiftRange])
                guard pattern.accepts(matched) else { continue }
                matchedExplicitPattern = true
                results.append(
                    ScanFinding(
                        id: pattern.id,
                        label: pattern.label,
                        kind: pattern.kind,
                        range: locatable ? swiftRange : nil
                    )
                )
            }
        }

        if matchedExplicitPattern == false {
            results.append(contentsOf: entropyFindings(in: view, locatable: locatable))
        }
        return results
    }

    private static func entropyFindings(in text: String, locatable: Bool) -> [ScanFinding] {
        guard let entropy = corpus.entropy, entropy.enabled, let regex = secretLikeTokenRegex else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [ScanFinding] = []
        for match in regex.matches(in: text, range: fullRange) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let token = String(text[swiftRange])
            guard token.count >= entropy.minLength,
                  token.count <= entropy.maxLength,
                  Set(token).count >= 10,
                  token.contains(where: { $0.isLetter }),
                  token.contains(where: { $0.isNumber }),
                  shannonEntropy(token) >= entropy.minShannonEntropy else {
                continue
            }
            results.append(
                ScanFinding(
                    id: highEntropyFindingID,
                    label: entropy.label,
                    kind: entropy.kind,
                    range: locatable ? swiftRange : nil
                )
            )
        }
        return results
    }

    /// Order-preserving dedup by id, mapping internal findings to the public type.
    private static func dedupedPublicFindings(_ scan: [ScanFinding]) -> [MemoryGateFinding] {
        var seen = Set<String>()
        var result: [MemoryGateFinding] = []
        for finding in scan where seen.insert(finding.id).inserted {
            result.append(MemoryGateFinding(id: finding.id, label: finding.label, kind: finding.kind))
        }
        return result
    }

    private static var unavailableFinding: MemoryGateFinding {
        MemoryGateFinding(id: corpusUnavailableFindingID, label: corpusUnavailableLabel, kind: .secret)
    }

    // MARK: - Derived views (decode / un-wrap evasion)

    private static func derivedViews(for text: String) -> [String] {
        var views: [String] = []
        let lineContinuations = text.replacingOccurrences(
            of: #"\\\s*\n\s*"#,
            with: "",
            options: .regularExpression
        )
        if lineContinuations != text {
            views.append(lineContinuations)
        }
        let joinedStringLiterals = text.replacingOccurrences(
            of: #"["']\s*(?:\\\s*)?\n\s*["']"#,
            with: "",
            options: .regularExpression
        )
        if joinedStringLiterals != text, views.contains(joinedStringLiterals) == false {
            views.append(joinedStringLiterals)
        }
        views.append(contentsOf: decodedViews(for: text))
        return views
    }

    private static func decodedViews(for text: String) -> [String] {
        guard corpus.decoding?.enabled == true else { return [] }
        let maxCandidates = corpus.decoding?.maxCandidates ?? 32
        let maxDecodedBytes = corpus.decoding?.maxDecodedBytes ?? 8_192
        var views: [String] = []

        if let base64CandidateRegex {
            for candidate in matches(regex: base64CandidateRegex, text: text) {
                guard views.count < maxCandidates else { break }
                var raw = candidate
                let remainder = raw.count % 4
                if remainder != 0 {
                    raw += String(repeating: "=", count: 4 - remainder)
                }
                guard let decoded = Data(base64Encoded: raw, options: []),
                      decoded.isEmpty == false,
                      decoded.count <= maxDecodedBytes,
                      let view = String(data: decoded, encoding: .utf8) else {
                    continue
                }
                views.append(view)
            }
        }

        if let hexCandidateRegex {
            for candidate in matches(regex: hexCandidateRegex, text: text) {
                guard views.count < maxCandidates else { break }
                let evenMatch = candidate.count.isMultiple(of: 2) ? candidate : String(candidate.dropLast())
                guard let decoded = Data(memoryGateHexEncoded: evenMatch),
                      decoded.isEmpty == false,
                      decoded.count <= maxDecodedBytes,
                      let view = String(data: decoded, encoding: .utf8) else {
                    continue
                }
                views.append(view)
            }
        }

        return views
    }

    private static func matches(regex: NSRegularExpression, text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func shannonEntropy(_ value: String) -> Double {
        let bytes = Array(value.utf8)
        guard bytes.isEmpty == false else { return 0 }
        var counts: [UInt8: Int] = [:]
        for byte in bytes {
            counts[byte, default: 0] += 1
        }
        let length = Double(bytes.count)
        return counts.values.reduce(0.0) { partial, count in
            let probability = Double(count) / length
            return partial - probability * log2(probability)
        }
    }

    // MARK: - Compiled regexes for decode candidates / entropy tokens

    private static let base64CandidateRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9+/=])(?:[A-Za-z0-9+/]{32,}={0,2})(?![A-Za-z0-9+/=])"#
    )
    private static let hexCandidateRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Fa-f0-9])(?:[A-Fa-f0-9]{48,})(?![A-Fa-f0-9])"#
    )
    private static let secretLikeTokenRegex = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9_+/=.-]{32,}"#
    )

    // MARK: - Corpus model + loading

    /// A pattern compiled from the corpus plus the post-match validator the corpus
    /// declared (`luhn` / `ipv4Octets`). The validator is mandatory: a loose regex
    /// that matched but failed its validator is NOT a finding.
    struct CompiledPattern {
        enum Validator {
            case none
            case luhn
            case ipv4Octets
        }

        let id: String
        let label: String
        let kind: MemoryGateFindingKind
        let regex: NSRegularExpression
        let validator: Validator

        func accepts(_ matched: String) -> Bool {
            switch validator {
            case .none:
                return true
            case .luhn:
                return MemorySecretPIIGate.passesLuhn(matched)
            case .ipv4Octets:
                return MemorySecretPIIGate.hasBoundedIPv4Octets(matched)
            }
        }
    }

    struct LoadedCorpus {
        let version: String
        let patterns: [CompiledPattern]
        let entropy: EntropyConfig?
        let decoding: DecodingConfig?
        let available: Bool

        static let unavailable = LoadedCorpus(
            version: "",
            patterns: [],
            entropy: nil,
            decoding: nil,
            available: false
        )
    }

    struct EntropyConfig {
        let enabled: Bool
        let label: String
        let kind: MemoryGateFindingKind
        let minLength: Int
        let maxLength: Int
        let minShannonEntropy: Double
    }

    struct DecodingConfig {
        let enabled: Bool
        let maxCandidates: Int
        let maxDecodedBytes: Int
    }

    private static let corpus: LoadedCorpus = loadCorpus()

    private static func loadCorpus() -> LoadedCorpus {
        guard let data = corpusData(),
              let decoded = try? JSONDecoder().decode(RawCorpus.self, from: data) else {
            return .unavailable
        }

        var compiled: [CompiledPattern] = []
        for spec in decoded.patterns {
            var options: NSRegularExpression.Options = []
            if spec.caseInsensitive == true { options.insert(.caseInsensitive) }
            if spec.dotMatchesNewlines == true { options.insert(.dotMatchesLineSeparators) }
            if spec.anchorsMatchLines == true { options.insert(.anchorsMatchLines) }
            guard let regex = try? NSRegularExpression(pattern: spec.regex, options: options) else {
                // Corrupt pattern => fail closed for the whole gate.
                return .unavailable
            }
            guard let kind = MemoryGateFindingKind(rawValue: spec.kind) else {
                return .unavailable
            }
            compiled.append(
                CompiledPattern(
                    id: spec.id,
                    label: spec.label,
                    kind: kind,
                    regex: regex,
                    validator: validator(for: spec.validator)
                )
            )
        }

        let entropy: EntropyConfig? = decoded.entropy.flatMap { raw in
            guard let kind = MemoryGateFindingKind(rawValue: raw.kind ?? MemoryGateFindingKind.secret.rawValue) else {
                return nil
            }
            return EntropyConfig(
                enabled: raw.enabled,
                label: raw.label,
                kind: kind,
                minLength: raw.minLength,
                maxLength: raw.maxLength,
                minShannonEntropy: raw.minShannonEntropy
            )
        }
        let decoding = decoded.decoding.map { raw in
            DecodingConfig(enabled: raw.enabled, maxCandidates: raw.maxCandidates, maxDecodedBytes: raw.maxDecodedBytes)
        }

        return LoadedCorpus(
            version: decoded.version,
            patterns: compiled,
            entropy: entropy,
            decoding: decoding,
            available: true
        )
    }

    private static func validator(for raw: String?) -> CompiledPattern.Validator {
        switch raw {
        case "luhn": .luhn
        case "ipv4Octets": .ipv4Octets
        default: .none
        }
    }

    static let corpusFileBaseName = "secret-pattern-corpus"
    static let corpusFileName = "secret-pattern-corpus.json"
    static let corpusEnvironmentKey = "OPENBURNBAR_CODE_SECRET_CORPUS_PATH"
    static let installedResourceDirectoryName = "ProjectCodeMemory"

    /// Resolve the corpus bytes. Primary loader is `Bundle.module` by FLAT
    /// filename (Core's resources are declared with `.process` which flattens
    /// nested folders — there is no `subdirectory:`). Falls back to an explicit
    /// env override and a bounded upward filesystem walk so the daemon executable
    /// (where `Bundle.module` resource synthesis can be unreliable) and locally
    /// staged app bundles still resolve.
    private static func corpusData() -> Data? {
        if let url = Bundle.module.url(forResource: corpusFileBaseName, withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        if let url = filesystemCorpusURL(), let data = try? Data(contentsOf: url) {
            return data
        }
        return nil
    }

    private static func filesystemCorpusURL() -> URL? {
        let fileManager = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment[corpusEnvironmentKey], explicit.isEmpty == false {
            let url = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        var bases: [URL] = [URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)]
        if let resourceURL = Bundle.main.resourceURL { bases.append(resourceURL) }
        if let executableURL = Bundle.main.executableURL { bases.append(executableURL.deletingLastPathComponent()) }
        bases.append(Bundle.main.bundleURL)
        bases.append(URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent())

        for base in bases {
            var cursor = base.standardizedFileURL
            for _ in 0..<8 {
                for candidate in corpusCandidates(under: cursor) where fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        return nil
    }

    private static func corpusCandidates(under base: URL) -> [URL] {
        [
            base.appendingPathComponent(corpusFileName, isDirectory: false),
            base
                .appendingPathComponent(installedResourceDirectoryName, isDirectory: true)
                .appendingPathComponent(corpusFileName, isDirectory: false),
            base
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(installedResourceDirectoryName, isDirectory: true)
                .appendingPathComponent(corpusFileName, isDirectory: false),
            base
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(installedResourceDirectoryName, isDirectory: true)
                .appendingPathComponent(corpusFileName, isDirectory: false),
            base
                .appendingPathComponent("tools", isDirectory: true)
                .appendingPathComponent("project-code-memory", isDirectory: true)
                .appendingPathComponent(corpusFileName, isDirectory: false)
        ]
    }

    // MARK: - Validators

    /// Luhn (mod-10) checksum over the digits in `value`. Mandatory for
    /// credit-card matches: without it the loose `(?:\d[ -]*?){13,19}` regex would
    /// reject (and, under redact, delete) any 13–19 digit run — version strings,
    /// order numbers, formatted identifiers. We require 13–19 digits AND a valid
    /// checksum.
    static func passesLuhn(_ value: String) -> Bool {
        let digits = value.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        var double = false
        for digit in digits.reversed() {
            var current = digit
            if double {
                current *= 2
                if current > 9 { current -= 9 }
            }
            sum += current
            double.toggle()
        }
        return sum % 10 == 0
    }

    /// Every dotted octet must parse and be in 0...255. Without this bound the
    /// corpus regex `\b(?:\d{1,3}\.){3}\d{1,3}\b` matches version strings like
    /// `999.888.777.666`, silently deleting legitimate memories.
    static func hasBoundedIPv4Octets(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard octet.isEmpty == false,
                  octet.allSatisfy(\.isNumber),
                  let number = Int(octet),
                  (0...255).contains(number) else {
                return false
            }
        }
        return true
    }

    // MARK: - Raw decodable corpus

    private struct RawCorpus: Decodable {
        struct Pattern: Decodable {
            let id: String
            let label: String
            let kind: String
            let regex: String
            let caseInsensitive: Bool?
            let dotMatchesNewlines: Bool?
            let anchorsMatchLines: Bool?
            let validator: String?
        }

        struct Entropy: Decodable {
            let enabled: Bool
            let label: String
            let kind: String?
            let minLength: Int
            let maxLength: Int
            let minShannonEntropy: Double
        }

        struct DecodingConfig: Decodable {
            let enabled: Bool
            let maxCandidates: Int
            let maxDecodedBytes: Int
        }

        let version: String
        let patterns: [Pattern]
        let entropy: Entropy?
        let decoding: DecodingConfig?
    }
}

private extension Data {
    init?(memoryGateHexEncoded raw: String) {
        guard raw.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count / 2)
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(index, offsetBy: 2)
            guard let byte = UInt8(raw[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
