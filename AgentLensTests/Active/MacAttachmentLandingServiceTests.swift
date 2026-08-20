import CryptoKit
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
    }

    func testDoubleDeliveryDedupeByVerifiedDigest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain.bin")
        try Data("hello-land".utf8).write(to: source)
        let digest = SHA256.hash(data: Data("hello-land".utf8)).map { String(format: "%02x", $0) }.joined()
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
    }

    func testMissingKeyFailsClosed() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x")
        XCTAssertThrowsError(
            try MacAttachmentLandingService.land(
                plaintextURL: url,
                declaredContentBlake3: "00",
                filename: "x",
                roots: [FileManager.default.temporaryDirectory],
                contentKey: nil
            )
        ) { error in
            XCTAssertEqual(error as? MacAttachmentLandingService.Error, .missingContentKey)
        }
    }

    func testCapsAre2GiB() {
        XCTAssertEqual(FileSealAEAD.maxPlaintextBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(IrohBlobTransferLimits.maxExpectedFetchBytes, 2 * 1024 * 1024 * 1024)
    }
}
