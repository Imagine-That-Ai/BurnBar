import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import OpenBurnBarDaemon

final class BurnBarFleetGrokBotInputListenerTests: XCTestCase {
    func testBindLoopbackIsLocalhost() throws {
        let bound = try BurnBarFleetGrokBotInputListener.bindLoopback(port: 0)
        defer { close(bound.fd) }
        XCTAssertGreaterThan(bound.port, 0)
        XCTAssertNil(BurnBarFleetGrokBotInputListener.peerCredentials(socketFD: bound.fd))
    }

    func testUnauthenticatedLoopbackIsRejected() {
        let listener = BurnBarFleetGrokBotInputListener(auth: .none)
        XCTAssertThrowsError(try listener.accept(input: "hi", remoteAddress: "127.0.0.1")) { error in
            XCTAssertEqual(error as? BurnBarFleetGrokBotInputListener.Error, .unauthenticatedLoopback)
        }
    }

    func testNonLoopbackIsRejectedEvenWithPeer() {
        let listener = BurnBarFleetGrokBotInputListener(
            auth: .peerCredential(expectedPid: getpid()),
            evaluate: { _ in true }
        )
        XCTAssertThrowsError(
            try listener.accept(
                input: "hi",
                remoteAddress: "10.0.0.2",
                peerUid: getuid(),
                peerPid: getpid()
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarFleetGrokBotInputListener.Error, .unauthenticatedLoopback)
        }
    }

    func testPeerCredentialRequiresMatchingUid() {
        let listener = BurnBarFleetGrokBotInputListener(
            auth: .peerCredential(expectedPid: getpid()),
            evaluate: { _ in true }
        )
        XCTAssertThrowsError(try listener.accept(input: "hi", remoteAddress: "127.0.0.1")) { error in
            XCTAssertEqual(error as? BurnBarFleetGrokBotInputListener.Error, .unauthenticatedLoopback)
        }
        XCTAssertEqual(
            try listener.accept(
                input: "hi",
                remoteAddress: "127.0.0.1",
                peerUid: getuid(),
                peerPid: getpid()
            ),
            "hi"
        )
    }

    func testTokenFileComparesBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("token")
        let token = Data("secret-token".utf8)
        try token.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let listener = BurnBarFleetGrokBotInputListener(
            auth: .tokenFile(url: url),
            evaluate: { $0 == "hi" }
        )
        XCTAssertThrowsError(
            try listener.accept(input: "hi", remoteAddress: "127.0.0.1", presentedToken: Data("nope".utf8))
        )
        XCTAssertEqual(
            try listener.accept(input: "hi", remoteAddress: "127.0.0.1", presentedToken: token),
            "hi"
        )
    }
}
