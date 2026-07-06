import XCTest
@testable import OpenBurnBar

/// Governance: every macOS `AnalyticsEvent` must be registered in the canonical
/// taxonomy (`docs/analytics/event-taxonomy.md`) — an off-taxonomy name fails CI.
/// This is the macOS counterpart of the website / console / extension / backend /
/// android / apple governance tests; together they make the doc the enforceable
/// single source of truth its § Governance promises.
final class AnalyticsTaxonomyTests: XCTestCase {

    /// Event wire-names registered in the canonical doc — backtick-wrapped
    /// `surface.object.action` tokens (≥1 dot); domains are excluded.
    private func registeredEventNames() throws -> Set<String> {
        let mainBundlePath = Bundle.main.bundlePath
        if mainBundlePath.contains("/openburnbar-app-tests/") {
            throw XCTSkip("Skipping taxonomy validation in sandboxed test runner.")
        }
        
        let docURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Active
            .deletingLastPathComponent() // AgentLensTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("docs/analytics/event-taxonomy.md")
        let doc = try String(contentsOf: docURL, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "`([a-z0-9_]+(?:\\.[a-z0-9_]+)+)`")
        var names = Set<String>()
        for match in regex.matches(in: doc, range: NSRange(doc.startIndex..., in: doc)) {
            guard let range = Range(match.range(at: 1), in: doc) else { continue }
            let token = String(doc[range])
            if token.hasSuffix(".com") || token.hasSuffix(".ai") || token.hasSuffix(".net")
                || token.hasSuffix(".org") || token.hasSuffix(".io") { continue }
            names.insert(token)
        }
        return names
    }

    func test_taxonomyDocParsesToANonTrivialSet() throws {
        let registered = try registeredEventNames()
        XCTAssertGreaterThan(registered.count, 20, "taxonomy parse produced too few event names")
        XCTAssertTrue(registered.contains("screen.viewed"))
        XCTAssertTrue(registered.contains("consent.analytics.granted"))
    }

    func test_everyMacEventIsRegisteredInTaxonomy() throws {
        let registered = try registeredEventNames()
        let offTaxonomy = AnalyticsEvent.allCases
            .map(\.rawValue)
            .filter { !registered.contains($0) }
        XCTAssertTrue(
            offTaxonomy.isEmpty,
            "off-taxonomy macOS events (add them to docs/analytics/event-taxonomy.md): \(offTaxonomy.sorted().joined(separator: ", "))"
        )
    }
}
