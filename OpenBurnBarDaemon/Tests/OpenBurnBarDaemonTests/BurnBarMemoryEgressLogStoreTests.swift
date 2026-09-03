@testable import OpenBurnBarDaemon
import XCTest

/// Every memory-purpose request leaves one content-free, hash-chained entry.
final class BurnBarMemoryEgressLogStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-egress-\(UUID().uuidString).jsonl", isDirectory: false)
    }

    private func entry(seq: Int, outcome: String = "allowed") -> BurnBarMemoryEgressEntry {
        BurnBarMemoryEgressEntry(
            purpose: "memory-extract",
            providerID: "openrouter",
            modelID: "anthropic/claude-opus-5",
            requestBytes: 1_200,
            responseBytes: 400,
            retention: "deny",
            outcome: outcome,
            code: outcome == "allowed" ? nil : "BUDGET_EXCEEDED",
            latencyMs: 250
        )
    }

    func test_appendChainsHashesAndVerifyPasses() async throws {
        let store = BurnBarMemoryEgressLogStore(fileURL: temporaryURL())
        try await store.append(entry(seq: 1))
        try await store.append(entry(seq: 2, outcome: "denied"))
        let entries = try await store.entries()
        XCTAssertEqual(entries.map(\.seq), [1, 2])
        XCTAssertEqual(entries[1].prevHash, entries[0].hash)
        XCTAssertNil(entries[0].code)
        XCTAssertEqual(entries[1].code, "BUDGET_EXCEEDED")
        let verification = try await store.verify()
        XCTAssertTrue(verification.ok)
        XCTAssertEqual(verification.events, 2)
        XCTAssertNil(verification.brokenAtSeq)
    }

    func test_tamperedLineBreaksTheChain() async throws {
        let url = temporaryURL()
        let store = BurnBarMemoryEgressLogStore(fileURL: url)
        try await store.append(entry(seq: 1))
        try await store.append(entry(seq: 2))
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[0] = lines[0].replacingOccurrences(of: "\"requestBytes\":1200", with: "\"requestBytes\":1")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let verification = try await BurnBarMemoryEgressLogStore(fileURL: url).verify()
        XCTAssertFalse(verification.ok)
        XCTAssertEqual(verification.brokenAtSeq, 1)
    }

    func test_entriesCarryNoContentFields() throws {
        let data = try JSONEncoder().encode(entry(seq: 1))
        let keys = Set((try JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys ?? [String: Any]().keys)
        XCTAssertTrue(keys.isDisjoint(with: ["body", "text", "messages", "prompt", "input", "content"]))
    }
}
