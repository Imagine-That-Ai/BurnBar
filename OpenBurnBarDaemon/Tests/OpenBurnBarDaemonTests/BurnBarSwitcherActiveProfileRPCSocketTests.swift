import Darwin
import Foundation
import GRDB
import OpenBurnBarKernel
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Wave 2.1c-v: `daemon.switcher.active_profile.apply` exercised end to end
/// through the production dispatch — real Unix socket, `responseData`
/// routing, `handleSwitcherRPC`, and the lane.
///
/// These tests prove the wire contract, not the storage semantics (those
/// live in `BurnBarSwitcherActiveProfileLaneTests`): a valid apply returns
/// its counts, a malformed apply is the caller's fault (`invalidParams`), a
/// storage failure is an `internalError` with nothing partially applied,
/// and a missing store fails closed instead of writing nowhere.
///
/// The store is injected over an in-memory queue rather than bootstrapped
/// from a file: the file bootstrap keys itself from the Keychain when a
/// SQLCipher codec is linked, which would couple this test to the dev
/// machine's keychain instead of the wire contract.
final class BurnBarSwitcherActiveProfileRPCSocketTests: XCTestCase {
    private let authToken = "switcher-rpc-test-token"

    func test_switcherActiveProfileApplyDispatchesThroughTheServerSocket() async throws {
        let rootURL = try makeTemporaryRoot(name: "switcher-rpc")
        let dbQueue = try DatabaseQueue()
        try await dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE switcher_active_profile (
                    activeProfileID TEXT,
                    providerID TEXT,
                    updatedAt TEXT NOT NULL
                )
            """)
        }

        let socketPath = makeSocketPath(name: "switcher")
        let server = makeServer(
            rootURL: rootURL,
            socketPath: socketPath,
            indexDatabasePath: nil,
            switcherProfileStore: BurnBarSwitcherSQLiteProfileStore(dbQueue: dbQueue)
        )
        try await server.start()
        addTeardownBlock { await server.stop() }

        // 1. A valid global+mirror batch commits over the wire and returns
        // its counts.
        let applied: BurnBarRPCResponseEnvelope<BurnBarSwitcherActiveProfileApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "apply",
                method: .switcherActiveProfileApply,
                authToken: authToken,
                params: BurnBarSwitcherActiveProfileApplyRequest(sets: [
                    BurnBarSwitcherActiveProfileSet(profileID: "profile-1"),
                    BurnBarSwitcherActiveProfileSet(profileID: "profile-1", providerID: "claude-code")
                ])
            ),
            socketPath: socketPath
        )
        XCTAssertNil(applied.error)
        let appliedResult = try XCTUnwrap(applied.result)
        XCTAssertEqual(appliedResult.setsApplied, 2)
        XCTAssertEqual(appliedResult.rowsCleared, 0)

        // 2. A malformed apply is the caller's fault, not an internal error.
        let rejected: BurnBarRPCResponseEnvelope<BurnBarSwitcherActiveProfileApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "malformed",
                method: .switcherActiveProfileApply,
                authToken: authToken,
                params: BurnBarSwitcherActiveProfileApplyRequest()
            ),
            socketPath: socketPath
        )
        XCTAssertNil(rejected.result)
        XCTAssertEqual(rejected.error?.code, BurnBarRPCErrorCode.invalidParams)

        // 3. A storage failure is an internal error: drop the table out from
        // under the store and the next apply fails with nothing written.
        try await dbQueue.write { db in
            try db.execute(sql: "DROP TABLE switcher_active_profile")
        }
        let failed: BurnBarRPCResponseEnvelope<BurnBarSwitcherActiveProfileApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "missing-table",
                method: .switcherActiveProfileApply,
                authToken: authToken,
                params: BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: "profile-2")])
            ),
            socketPath: socketPath
        )
        XCTAssertNil(failed.result)
        XCTAssertEqual(failed.error?.code, BurnBarRPCErrorCode.internalError)
    }

    func test_switcherActiveProfileApplyFailsClosedWithoutAStore() async throws {
        let rootURL = try makeTemporaryRoot(name: "switcher-rpc-unavailable")
        let socketPath = makeSocketPath(name: "switcher-unavail")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: nil)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarSwitcherActiveProfileApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "unavailable",
                method: .switcherActiveProfileApply,
                authToken: authToken,
                params: BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: "profile-1")])
            ),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.unavailable)
    }

    // MARK: - Server construction

    private func makeServer(
        rootURL: URL,
        socketPath: String,
        indexDatabasePath: String?,
        switcherProfileStore: BurnBarSwitcherSQLiteProfileStore? = nil
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: authToken,
                indexDatabasePath: indexDatabasePath,
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "switcher-rpc-tests"),
            configStore: BurnBarConfigStore(
                fileURL: rootURL.appendingPathComponent("provider-config.json"),
                secretStore: BurnBarInMemorySecretStore(),
                logger: BurnBarDaemonLogger(category: "switcher-rpc-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: rootURL.appendingPathComponent("usage-events.jsonl")
            ),
            switcherProfileStore: switcherProfileStore
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return rootURL
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/obb-switcher-\(name)-\(String(UUID().uuidString.prefix(8))).sock"
    }

    // MARK: - Socket transport

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        let payload = try JSONEncoder().encode(envelope) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }
        while response.last == 0x0A || response.last == 0x0D { response.removeLast() }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { rawBuffer[index] = byte }
        }
        return address
    }
}
