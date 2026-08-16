@testable import BurnBarDaemon
import Darwin
import Foundation
import XCTest

/// Owner-only Unix-socket policy (VAL-HARD-023).
final class BurnBarFleetSocketSecurityTests: BurnBarFleetRPCTestCase {
    func testFleetSocket_isOwnerOnly_andServesSameUser() async throws {
        let configuration = makeConfiguration(name: "socket-security")
        let fleetService = makeFleetService(cadenceSeconds: 1)
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        addTeardownBlock {
            await server.stop()
        }

        var fileStatus = stat()
        XCTAssertEqual(lstat(configuration.socketPath, &fileStatus), 0)
        XCTAssertEqual(fileStatus.st_uid, getuid())
        XCTAssertEqual(fileStatus.st_mode & 0o777, 0o600)

        let response = try rawRequest(
            #"{"id":"socket-security","method":"daemon.health"}"#,
            socketPath: configuration.socketPath
        )
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertNil(envelope.error)
        XCTAssertEqual(envelope.id, "socket-security")
    }
}
