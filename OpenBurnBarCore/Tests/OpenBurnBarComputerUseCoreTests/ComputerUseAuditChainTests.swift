import XCTest
@testable import OpenBurnBarComputerUseCore

final class ComputerUseAuditChainTests: XCTestCase {
    private let macAppVersion = "1.0.0"
    private let sessionId = ComputerUseSessionID("test-session-\(UUID().uuidString)")

    private func makeManifest(_ id: ComputerUseSessionID) -> ComputerUseSessionManifest {
        ComputerUseSessionManifest(
            sessionId: id,
            mode: .browser,
            trustMode: .manual,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            userId: "user-1",
            macHostNodeId: "node-mac",
            phoneViewerNodeId: nil,
            scopeRuleIds: [],
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: 50,
            sessionTimeoutSeconds: 1800
        )
    }

    private func makeAction() -> ComputerUseAction {
        .browser(BrowserAction(kind: .click, selector: "button[type=submit]"))
    }

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cu-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testManifestHashIsStableAcrossEncodes() throws {
        let chain = ComputerUseAuditChain()
        let manifest = makeManifest(sessionId)
        let h1 = try chain.hashSessionManifest(manifest)
        let h2 = try chain.hashSessionManifest(manifest)
        XCTAssertEqual(h1, h2, "Canonical-JSON encoding must hash deterministically across calls")
        XCTAssertEqual(h1.count, 64, "SHA-256 hex digest must be 64 chars")
    }

    func testChainHeadAdvancesOnAppend() throws {
        let dir = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: sessionId,
            baseDirectory: dir,
            macAppVersion: macAppVersion
        )
        let manifest = makeManifest(sessionId)
        try logger.beginSession(manifest: manifest)
        XCTAssertEqual(logger.nextEntryIndex, 0)
        XCTAssertNotEqual(logger.headHashHex, ComputerUseAuditHasher.genesisParentHashHex,
            "After beginSession the head must hash the manifest, not the genesis sentinel")

        let h0 = logger.headHashHex
        let entry = try logger.makeEntry(
            for: makeAction(),
            approvedBy: .mac
        )
        try logger.append(entry)
        XCTAssertEqual(logger.nextEntryIndex, 1)
        XCTAssertNotEqual(logger.headHashHex, h0)
    }

    func testWrittenChainValidates() throws {
        let dir = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: sessionId,
            baseDirectory: dir,
            macAppVersion: macAppVersion
        )
        let manifest = makeManifest(sessionId)
        try logger.beginSession(manifest: manifest)
        for _ in 0..<20 {
            let entry = try logger.makeEntry(for: makeAction(), approvedBy: .mac)
            try logger.append(entry)
        }
        let manifestHashHex = try ComputerUseAuditChain().hashSessionManifest(manifest)
        let chainFile = dir
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let result = try ComputerUseAuditChain().validate(
            at: chainFile,
            sessionManifestHashHex: manifestHashHex
        )
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.entryCount, 20)
        XCTAssertEqual(result.headHashHex, logger.headHashHex)
    }

    func testHundredEntryChainValidates() throws {
        let dir = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: sessionId,
            baseDirectory: dir,
            macAppVersion: macAppVersion
        )
        let manifest = makeManifest(sessionId)
        try logger.beginSession(manifest: manifest)
        for _ in 0..<100 {
            try logger.append(try logger.makeEntry(for: makeAction(), approvedBy: .mac))
        }
        let manifestHashHex = try ComputerUseAuditChain().hashSessionManifest(manifest)
        let chainURL = dir
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let result = try ComputerUseAuditChain().validate(
            at: chainURL,
            sessionManifestHashHex: manifestHashHex,
            expectedHeadHashHex: logger.headHashHex
        )
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.entryCount, 100)
        XCTAssertEqual(result.headHashHex, logger.headHashHex)
    }

    func testTamperAtEveryEntryReportsExpectedIndex() throws {
        let dir = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: sessionId,
            baseDirectory: dir,
            macAppVersion: macAppVersion
        )
        let manifest = makeManifest(sessionId)
        try logger.beginSession(manifest: manifest)
        for _ in 0..<100 {
            try logger.append(try logger.makeEntry(for: makeAction(), approvedBy: .mac))
        }
        let originalHead = logger.headHashHex
        let chainURL = dir
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let lines = try String(contentsOf: chainURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        for index in 0..<lines.count {
            var snapshot = lines
            // Tamper with `actionSummary` value. For non-terminal
            // entries the chain walk catches the change via
            // parent-hash mismatch at the next entry. For the terminal
            // entry, the parent-chain walk passes but the recomputed
            // head no longer matches the stored head — supplying
            // `expectedHeadHashHex` catches that.
            snapshot[index] = snapshot[index].replacingOccurrences(
                of: "\"actionSummary\":\"",
                with: "\"actionSummary\":\"tampered_"
            )
            let rejoined = snapshot.joined(separator: "\n") + "\n"
            let chain = ComputerUseAuditChain()
            let manifestHashHex = try chain.hashSessionManifest(manifest)
            let result = chain.validate(
                rawJSONLines: Data(rejoined.utf8),
                sessionManifestHashHex: manifestHashHex,
                expectedHeadHashHex: originalHead
            )
            XCTAssertFalse(result.isValid, "Tamper at index \(index) should be detected")
            if index == lines.count - 1 {
                XCTAssertEqual(result.firstInvalidEntryIndex, index)
                XCTAssertEqual(result.firstInvalidReason, .headHashMismatch)
                XCTAssertEqual(result.entryCount, lines.count)
            } else {
                XCTAssertEqual(result.firstInvalidEntryIndex, index + 1)
                XCTAssertEqual(result.firstInvalidReason, .parentHashMismatch)
                XCTAssertEqual(result.entryCount, index + 1)
            }
        }
    }

    func testEntryIndexGapIsDetected() throws {
        let dir = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: sessionId,
            baseDirectory: dir,
            macAppVersion: macAppVersion
        )
        let manifest = makeManifest(sessionId)
        try logger.beginSession(manifest: manifest)
        for _ in 0..<5 {
            try logger.append(try logger.makeEntry(for: makeAction(), approvedBy: .mac))
        }
        let chainURL = dir
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        var lines = try String(contentsOf: chainURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        lines.remove(at: 2)

        let manifestHashHex = try ComputerUseAuditChain().hashSessionManifest(manifest)
        let result = ComputerUseAuditChain().validate(
            rawJSONLines: Data((lines.joined(separator: "\n") + "\n").utf8),
            sessionManifestHashHex: manifestHashHex,
            expectedHeadHashHex: logger.headHashHex
        )

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.firstInvalidEntryIndex, 3)
        XCTAssertEqual(result.firstInvalidReason, .unexpectedEntryIndex)
        XCTAssertEqual(result.entryCount, 2)
    }

    func testAppendingWrongParentHashThrows() throws {
        let dir = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: sessionId,
            baseDirectory: dir,
            macAppVersion: macAppVersion
        )
        let manifest = makeManifest(sessionId)
        try logger.beginSession(manifest: manifest)

        let forged = ComputerUseAuditEntry(
            sessionId: sessionId.rawValue,
            entryIndex: 0,
            timestamp: Date(),
            actionKind: "browser.click",
            actionSummary: "Forged",
            actionDescriptorHashHex: String(repeating: "0", count: 64),
            approvalId: nil,
            approvedBy: .mac,
            scopeRuleId: nil,
            denyReason: nil,
            parentEntryHashHex: String(repeating: "f", count: 64),
            macAppVersion: macAppVersion
        )
        XCTAssertThrowsError(try logger.append(forged)) { error in
            guard case ComputerUseAuditLogger.AuditLoggerError.parentHashMismatch = error else {
                return XCTFail("Expected parentHashMismatch, got \(error)")
            }
        }
    }

    func testHeadMarkerWrittenAfterEachAppend() throws {
        let dir = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: sessionId,
            baseDirectory: dir,
            macAppVersion: macAppVersion
        )
        try logger.beginSession(manifest: makeManifest(sessionId))
        try logger.append(try logger.makeEntry(for: makeAction(), approvedBy: .mac))

        let headURL = dir
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("head.json")
        let data = try Data(contentsOf: headURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["index"] as? Int, 1)
        XCTAssertEqual(json?["hashHex"] as? String, logger.headHashHex)
        XCTAssertEqual(json?["sessionId"] as? String, sessionId.rawValue)
    }
}
