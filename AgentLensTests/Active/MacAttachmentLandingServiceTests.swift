import XCTest
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBar

final class MacAttachmentLandingServiceTests: XCTestCase {
    override func tearDown() {
        MacAttachmentLandingService.resetForTests()
        super.tearDown()
    }

    func testPathTraversalRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try MacAttachmentLandingService.containedURL(filename: "../etc/passwd", roots: [root]))
        XCTAssertThrowsError(try MacAttachmentLandingService.containedExistingFile(path: "../etc/passwd", roots: [root]))
        XCTAssertThrowsError(try MacAttachmentLandingService.containedExistingFile(path: "/etc/passwd", roots: [root]))
    }

    func testDoubleDeliveryDedupeByVerifiedDigest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain.bin")
        try Data("hello-land".utf8).write(to: source)
        let digest = ContentBlake3.hash(Data("hello-land".utf8))
        let key = Data(repeating: 7, count: 32)
        let first = try MacAttachmentLandingService.land(
            plaintextURL: source,
            declaredContentBlake3: digest,
            filename: "note.txt",
            roots: [root],
            contentKey: key,
            verifiedDigest: digest
        )
        let second = try MacAttachmentLandingService.land(
            plaintextURL: source,
            declaredContentBlake3: digest,
            filename: "note-copy.txt",
            roots: [root],
            contentKey: key,
            verifiedDigest: digest
        )
        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(first.contentBlake3, digest)
        let pending = MacAttachmentLandingService.takePending()
        XCTAssertFalse(pending.isEmpty)
        XCTAssertEqual(pending.first?.contentBlake3, digest)
        XCTAssertTrue(MacAttachmentLandingService.takePending().isEmpty)
    }

    func testTakePendingSurfacesLandedAttachmentForReceiver() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain.bin")
        try Data("hello-land".utf8).write(to: source)
        let digest = ContentBlake3.hash(Data("hello-land".utf8))
        _ = try MacAttachmentLandingService.land(
            plaintextURL: source,
            declaredContentBlake3: digest,
            filename: "note.txt",
            roots: [root],
            contentKey: Data(repeating: 7, count: 32),
            verifiedDigest: digest
        )
        let pending = MacAttachmentLandingService.takePending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].displayName, "note.txt")
        XCTAssertTrue(MacAttachmentLandingService.takePending().isEmpty)
    }

    func testMissingKeyFailsClosed() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x")
        XCTAssertThrowsError(
            try MacAttachmentLandingService.land(
                plaintextURL: url,
                declaredContentBlake3: "00",
                filename: "x",
                roots: [FileManager.default.temporaryDirectory],
                contentKey: nil,
                verifiedDigest: "00"
            )
        ) { error in
            XCTAssertEqual(error as? MacAttachmentLandingService.Error, .missingContentKey)
        }
    }

    func testDigestMismatchDoesNotLand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain.bin")
        try Data("hello-land".utf8).write(to: source)
        XCTAssertThrowsError(
            try MacAttachmentLandingService.land(
                plaintextURL: source,
                declaredContentBlake3: "aa".padding(toLength: 64, withPad: "a", startingAt: 0),
                filename: "note.txt",
                roots: [root],
                contentKey: Data(repeating: 7, count: 32),
                verifiedDigest: "bb".padding(toLength: 64, withPad: "b", startingAt: 0)
            )
        ) { error in
            XCTAssertEqual(error as? MacAttachmentLandingService.Error, .digestMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("note.txt").path))
    }

    func testFileSealCloudCapIs10GiBAndP2PCapIs2GiB() {
        XCTAssertEqual(FileSealAEAD.maxPlaintextBytes, 10 * 1024 * 1024 * 1024)
        XCTAssertEqual(IrohBlobTransferLimits.maxExpectedFetchBytes, 2 * 1024 * 1024 * 1024)
    }
}
