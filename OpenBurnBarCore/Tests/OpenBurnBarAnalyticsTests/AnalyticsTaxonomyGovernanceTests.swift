import Foundation
import XCTest
@testable import OpenBurnBarAnalytics

/// Governance gate tying the iOS/widget/keyboard event registry to the canonical
/// taxonomy doc (`docs/analytics/event-taxonomy.md`).
///
/// The taxonomy is the single source of truth: "Add the event here first. No
/// instrumentation call may reference an event name not in this file." Every
/// `AnalyticsEvent` case's wire name (`rawValue`) is referenced as an inline-code
/// `surface.object.action` token in the doc's tables. This test parses those
/// backtick-wrapped, dot-containing tokens into a registered-name set and asserts
/// **every** wire name in this platform's registry is a member of it. An
/// off-taxonomy name (renamed/typo/dropped from the doc) fails the build — so the
/// registry can never drift ahead of the documented contract.
final class AnalyticsTaxonomyGovernanceTests: XCTestCase {

    func test_everyAnalyticsEventWireName_isRegisteredInTaxonomyDoc() throws {
        let doc = try Self.taxonomyDocContents()
        let registered = Self.registeredWireNames(inTaxonomy: doc)

        // Sanity: the parser must actually find names (guards against a moved doc
        // or a broken regex silently passing with an empty set).
        XCTAssertGreaterThan(
            registered.count, 30,
            "Parsed too few event tokens from the taxonomy doc — the doc path or the extraction regex is wrong."
        )

        let wireNames = AnalyticsEvent.allCases.map(\.rawValue)
        XCTAssertFalse(wireNames.isEmpty, "AnalyticsEvent.allCases must not be empty")

        let offTaxonomy = wireNames.filter { !registered.contains($0) }
        XCTAssertTrue(
            offTaxonomy.isEmpty,
            """
            These AnalyticsEvent wire names are NOT registered in \
            docs/analytics/event-taxonomy.md (add them to the doc first, then \
            instrument): \(offTaxonomy.sorted().joined(separator: ", "))
            """
        )
    }

    /// Self-check: the gate has teeth. A deliberately off-taxonomy name must be
    /// rejected by the very set the real assertion trusts.
    func test_offTaxonomyName_isRejectedByTheGate() throws {
        let doc = try Self.taxonomyDocContents()
        let registered = Self.registeredWireNames(inTaxonomy: doc)
        XCTAssertFalse(
            registered.contains("totally.bogus.event_name"),
            "A name that does not appear in the taxonomy must not be considered registered."
        )
    }

    // MARK: - Helpers

    /// Backtick-wrapped tokens of the form `surface.object.action` (lowercase,
    /// dot-separated, snake within a segment) — the shape registered events take in
    /// the doc's tables. Mirrors the wire-name shape (`AnalyticsName.eventPattern`).
    private static let registeredTokenPattern = "`([a-z0-9]+(\\.[a-z0-9_]+)+)`"

    private static func registeredWireNames(inTaxonomy text: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: registeredTokenPattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var names = Set<String>()
        for match in matches where match.numberOfRanges > 1 {
            names.insert(ns.substring(with: match.range(at: 1)))
        }
        return names
    }

    /// Resolves the canonical taxonomy doc relative to THIS source file so the
    /// test runs from any working directory / CI checkout without bundling the doc
    /// as a package resource. Layout:
    /// `<repo>/OpenBurnBarCore/Tests/OpenBurnBarAnalyticsTests/<thisFile>` →
    /// `<repo>/docs/analytics/event-taxonomy.md` (three levels up).
    private static func taxonomyDocContents(file: StaticString = #filePath) throws -> String {
        let thisFile = URL(fileURLWithPath: "\(file)")
        let repoRoot = thisFile
            .deletingLastPathComponent()   // OpenBurnBarAnalyticsTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // OpenBurnBarCore/
            .deletingLastPathComponent()   // <repo>/
        let docURL = repoRoot
            .appendingPathComponent("docs")
            .appendingPathComponent("analytics")
            .appendingPathComponent("event-taxonomy.md")
        return try String(contentsOf: docURL, encoding: .utf8)
    }
}
