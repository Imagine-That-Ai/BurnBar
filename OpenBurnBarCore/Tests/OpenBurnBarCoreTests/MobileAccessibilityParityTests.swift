import XCTest
@testable import OpenBurnBarCore

final class MobileAccessibilityParityTests: XCTestCase {
    // Walks every fixture vector:
    // a11y.hero-burn.currency, a11y.hero-burn.tokens, a11y.hero-burn.live-rate,
    // a11y.quota-ring, a11y.stop-streaming, a11y.stop-idle,
    // a11y.inbox-row-unread, a11y.inbox-row-read, a11y.chart.live-cost,
    // a11y.icon-only.stop, a11y.loading.pulse, a11y.error.pulse,
    // a11y.live-stream.mercury
    func testWalksEveryA11yContractVector() throws {
        let vectors = try a11yVectors()
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            switch string(vector["kind"]) {
            case "heroBurn":
                assertHero(vector)
            case "quotaRing":
                XCTAssertEqual(
                    MobileAccessibilityLabelPolicy.quotaRing(
                        label: string(vector["label"]),
                        percentRemaining: int(vector["percentRemaining"])
                    ),
                    string(dict(vector["expected"])["label"])
                )
            case "stopButton":
                assertStop(vector)
            case "inboxRow":
                assertInbox(vector)
            case "chart":
                XCTAssertEqual(
                    MobileAccessibilityLabelPolicy.chart(
                        label: string(vector["label"]),
                        summary: string(vector["summary"])
                    ),
                    string(dict(vector["expected"])["label"])
                )
            case "iconOnly":
                XCTAssertEqual(
                    MobileAccessibilityLabelPolicy.iconOnly(action: string(vector["action"])),
                    string(dict(vector["expected"])["label"])
                )
            case "loading":
                XCTAssertEqual(
                    MobileAccessibilityLabelPolicy.loading(surface: string(vector["surface"])),
                    string(dict(vector["expected"])["label"])
                )
            case "error":
                XCTAssertEqual(
                    MobileAccessibilityLabelPolicy.error(surface: string(vector["surface"])),
                    string(dict(vector["expected"])["label"])
                )
            case "liveStream":
                XCTAssertEqual(
                    MobileAccessibilityLabelPolicy.liveStream(surface: string(vector["surface"])),
                    string(dict(vector["expected"])["label"])
                )
            default:
                XCTFail("unknown a11y vector \(string(vector["id"]))")
            }
        }
    }

    func testMissingLabelDoesNotMatchFixture() throws {
        let expected = try XCTUnwrap(try a11yVectors().first { string($0["id"]) == "a11y.hero-burn.currency" })
        let golden = string(dict(expected["expected"])["label"])
        let empty = MobileAccessibilityLabelPolicy.heroBurn(displayMode: "currency", heroText: "", liveRate: nil)
        XCTAssertTrue(empty.hasPrefix("Hero burn, currency"))
        XCTAssertNotEqual(empty, golden)
        XCTAssertTrue(empty.hasSuffix(", "))
    }

    private func assertHero(_ vector: [String: Any]) {
        XCTAssertEqual(
            MobileAccessibilityLabelPolicy.heroBurn(
                displayMode: string(vector["displayMode"]),
                heroText: string(vector["heroText"]),
                liveRate: vector["liveRate"] as? String
            ),
            string(dict(vector["expected"])["label"])
        )
    }

    private func assertStop(_ vector: [String: Any]) {
        XCTAssertEqual(
            MobileAccessibilityLabelPolicy.stopButton(isStreaming: bool(vector["isStreaming"])),
            string(dict(vector["expected"])["label"])
        )
    }

    private func assertInbox(_ vector: [String: Any]) {
        XCTAssertEqual(
            MobileAccessibilityLabelPolicy.inboxRow(
                unread: bool(vector["unread"]),
                kindLabel: string(vector["kindLabel"]),
                priorityLabel: vector["priorityLabel"] as? String,
                title: string(vector["title"])
            ),
            string(dict(vector["expected"])["label"])
        )
    }

    private func a11yVectors() throws -> [[String: Any]] {
        let url = repoRoot().appendingPathComponent("docs/mobile-parity/fixtures/product/a11y-contract-vectors.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["vectors"] as? [[String: Any]] ?? []
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private func string(_ value: Any?) -> String { value as? String ?? "" }
    private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private func bool(_ value: Any?) -> Bool { value as? Bool ?? false }
}
