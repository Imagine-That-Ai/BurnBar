import OpenBurnBarCore
import XCTest

final class HermesStreamEventTests: XCTestCase {
    func testEventVectorDecodesAndReencodesByteIdentically() throws {
        let fixture = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = JSONDecoder()
        let events = try decoder.decode([HermesStreamEvent].self, from: Data(fixture.utf8))

        XCTAssertEqual(events.count, 9)
        XCTAssertEqual(events.first, .messageChunk(text: "Hello "))
        XCTAssertEqual(
            events.last,
            .messageStop(
                finishReason: "stop",
                outcome: .normal,
                usage: HermesTokenUsageStats(
                    promptTokens: 10,
                    outputTokens: 20,
                    totalTokens: 30,
                    generationDurationSeconds: 1.25,
                    totalDurationSeconds: 2.5
                )
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(events)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), fixture)
    }

    func testUnknownFieldsAreIgnoredForForwardCompatibility() throws {
        let payload = #"{"type":"notice","level":"info","text":"hello","future":"ignored"}"#
        let decoded = try JSONDecoder().decode(HermesStreamEvent.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded, .notice(level: "info", text: "hello"))
    }

    private static let fixtureURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("HermesStreamEventVector.json")
    }()
}
