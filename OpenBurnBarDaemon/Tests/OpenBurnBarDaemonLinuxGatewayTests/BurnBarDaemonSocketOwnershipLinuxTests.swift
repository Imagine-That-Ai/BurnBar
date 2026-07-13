#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarDaemonSocketOwnershipLinuxTests: XCTestCase {
    func testSecondDaemonCannotDisruptHealthyOwner() async throws {
        let socketPath = makeSocketPath("single-owner")
        defer { removeLockFile(for: socketPath) }
        let first = makeServer(socketPath: socketPath)
        let second = makeServer(socketPath: socketPath)

        try await first.start()
        do {
            try await second.start()
            XCTFail("second daemon unexpectedly acquired the live socket")
        } catch BurnBarDaemonError.daemonAlreadyRunning(let path) {
            XCTAssertEqual(path, socketPath)
        }

        let health = try requestHealth(socketPath: socketPath)
        XCTAssertEqual(health.result?.ok, true)
        XCTAssertNil(health.error)

        await first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStaleSocketIsRecoveredOnlyWhileOwnershipLockIsHeld() async throws {
        let socketPath = makeSocketPath("stale-recovery")
        defer { removeLockFile(for: socketPath) }
        let staleDescriptor = try makeBoundSocket(at: socketPath)
        close(staleDescriptor)

        let server = makeServer(socketPath: socketPath)
        try await server.start()
        XCTAssertEqual(try requestHealth(socketPath: socketPath).result?.ok, true)
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testShutdownPreservesSocketPathReplacement() async throws {
        let socketPath = makeSocketPath("identity")
        defer { removeLockFile(for: socketPath) }
        let server = makeServer(socketPath: socketPath)
        try await server.start()

        XCTAssertEqual(unlink(socketPath), 0)
        let replacementDescriptor = try makeBoundSocket(at: socketPath)
        defer {
            close(replacementDescriptor)
            _ = unlink(socketPath)
        }

        await server.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStartupRefusesAndPreservesNonSocketPath() async throws {
        let socketPath = makeSocketPath("regular-file")
        defer { removeLockFile(for: socketPath) }
        try Data("do-not-delete".utf8).write(to: URL(fileURLWithPath: socketPath))
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = makeServer(socketPath: socketPath)
        do {
            try await server.start()
            XCTFail("daemon unexpectedly replaced a regular file")
        } catch BurnBarDaemonError.unexpectedExistingItem(let path) {
            XCTAssertEqual(path, socketPath)
        }
        XCTAssertEqual(try String(contentsOfFile: socketPath, encoding: .utf8), "do-not-delete")
    }

    func testActiveLegacySocketWithoutLockIsNeverUnlinked() async throws {
        let socketPath = makeSocketPath("legacy-owner")
        defer {
            _ = unlink(socketPath)
            removeLockFile(for: socketPath)
        }
        let legacyDescriptor = try makeBoundSocket(at: socketPath)
        defer { close(legacyDescriptor) }
        XCTAssertEqual(listen(legacyDescriptor, 1), 0)

        let server = makeServer(socketPath: socketPath)
        do {
            try await server.start()
            XCTFail("daemon unexpectedly unlinked an accepting legacy socket")
        } catch BurnBarDaemonError.activeSocketAlreadyExists(let path) {
            XCTAssertEqual(path, socketPath)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStartupRefusesHardLinkedLockFileWithoutMutatingTarget() async throws {
        let socketPath = makeSocketPath("hard-linked-lock")
        let lockPath = socketPath + ".lock"
        let targetPath = socketPath + ".target"
        try Data("lock-target".utf8).write(to: URL(fileURLWithPath: targetPath))
        XCTAssertEqual(chmod(targetPath, mode_t(0o644)), 0)
        XCTAssertEqual(link(targetPath, lockPath), 0)
        defer {
            _ = unlink(lockPath)
            _ = unlink(targetPath)
            _ = unlink(socketPath)
        }

        let server = makeServer(socketPath: socketPath)
        do {
            try await server.start()
            XCTFail("daemon unexpectedly accepted a hard-linked lock file")
        } catch BurnBarDaemonError.unexpectedExistingItem(let path) {
            XCTAssertEqual(path, lockPath)
        }

        var status = stat()
        XCTAssertEqual(lstat(targetPath, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o644))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    private func makeServer(socketPath: String) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "ownership-test-token",
                startsMissionControlBackgroundLoops: false
            )
        )
    }

    private func makeSocketPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-owner-\(name)-\(UUID().uuidString).sock")
            .path
    }

    private func removeLockFile(for socketPath: String) {
        _ = unlink(socketPath + ".lock")
    }

    private func makeBoundSocket(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor != -1 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do {
            var address = try socketAddress(path: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.stride))
                }
            }
            guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func requestHealth(
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<BurnBarHealthResponse> {
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor != -1 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        var address = try socketAddress(path: socketPath)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connected == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let request = BurnBarRPCRequestEnvelope(
            id: "ownership-health",
            method: .health,
            authToken: "ownership-test-token"
        )
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Glibc.write(descriptor, base.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        _ = shutdown(descriptor, Int32(SHUT_WR))

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            response.append(contentsOf: buffer.prefix(count))
            if response.last == 0x0A { break }
        }
        return try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarHealthResponse>.self,
            from: response
        )
    }

    private func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BurnBarDaemonError.socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                destination[index] = UInt8(bitPattern: byte)
            }
        }
        return address
    }
}
#endif
