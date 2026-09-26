import OpenBurnBarEngine
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarProviderRoutingDecisionEventStoreTests: XCTestCase {
    func testAppendRotatesLiveFileAtSizeBound() async throws {
        let fileURL = try temporaryLogURL()
        // Seed a live file just over the bound. Rotation only stats the
        // size, so the content is opaque padding.
        let seed = Data(repeating: 0x41, count: BurnBarProviderRoutingDecisionEventStore.maxBytes + 1)
        try seed.write(to: fileURL)
        let store = BurnBarProviderRoutingDecisionEventStore(
            fileURL: fileURL,
            logger: BurnBarDaemonLogger(category: "routing-decision-store-tests")
        )

        await store.append(makeEvent(reason: "rotation-probe-live"))

        let rotated = fileURL.appendingPathExtension("1")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotated.path),
            "the over-bound live file must move to .1 on append"
        )
        XCTAssertEqual(try Data(contentsOf: rotated), seed)
        let liveSize = try fileSize(of: fileURL)
        XCTAssertLessThan(
            liveSize,
            BurnBarProviderRoutingDecisionEventStore.maxBytes,
            "the live file restarts small after rotation"
        )
        let live = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(
            live.contains("rotation-probe-live"),
            "rotation must never lose the event being appended"
        )
    }

    func testRotationDropsOldestGenerationAndKeepsThree() async throws {
        let fileURL = try temporaryLogURL()
        let over = BurnBarProviderRoutingDecisionEventStore.maxBytes + 1
        try Data(repeating: 0x4C, count: over).write(to: fileURL)
        try Data("gen-one".utf8).write(to: fileURL.appendingPathExtension("1"))
        try Data("gen-two".utf8).write(to: fileURL.appendingPathExtension("2"))
        try Data("gen-three".utf8).write(to: fileURL.appendingPathExtension("3"))
        let store = BurnBarProviderRoutingDecisionEventStore(
            fileURL: fileURL,
            logger: BurnBarDaemonLogger(category: "routing-decision-store-tests")
        )

        await store.append(makeEvent(reason: "rotation-probe-shift"))

        XCTAssertEqual(try Data(contentsOf: fileURL.appendingPathExtension("3")), Data("gen-two".utf8))
        XCTAssertEqual(try Data(contentsOf: fileURL.appendingPathExtension("2")), Data("gen-one".utf8))
        XCTAssertEqual(try Data(contentsOf: fileURL.appendingPathExtension("1")).count, over)
        let directory = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(directory.count, 4, "live + three rotated generations, oldest dropped")
    }

    func testRotatedAndLiveFilesKeepPrivatePermissions() async throws {
        let fileURL = try temporaryLogURL()
        let seed = Data(repeating: 0x41, count: BurnBarProviderRoutingDecisionEventStore.maxBytes + 1)
        try seed.write(to: fileURL)
        // Seed legacy-loose perms: rotation must tighten, not preserve them.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let store = BurnBarProviderRoutingDecisionEventStore(
            fileURL: fileURL,
            logger: BurnBarDaemonLogger(category: "routing-decision-store-tests")
        )

        await store.append(makeEvent(reason: "rotation-probe-perms"))

        for url in [fileURL, fileURL.appendingPathExtension("1")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(
                attributes[.posixPermissions] as? NSNumber,
                NSNumber(value: 0o600),
                "\(url.lastPathComponent) must stay owner-only"
            )
        }
    }

    private func temporaryLogURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-decision-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("provider-routing-decisions.jsonl")
    }

    private func makeEvent(reason: String) -> ProviderRoutingDecisionEvent {
        ProviderRoutingDecisionEvent(
            occurredAt: Date(timeIntervalSince1970: 1_766_577_600),
            modelID: "probe-model",
            selected: nil,
            nextFallback: nil,
            reason: reason,
            skipped: []
        )
    }

    private func fileSize(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
