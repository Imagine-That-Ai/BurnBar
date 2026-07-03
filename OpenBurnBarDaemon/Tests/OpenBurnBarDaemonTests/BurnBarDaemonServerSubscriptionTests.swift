import OpenBurnBarCore
@testable import OpenBurnBarDaemon
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest

final class BurnBarDaemonServerSubscriptionTests: XCTestCase {
    func testSubscriptionStartResumeAndRestartReacquireOverSocket() async throws {
        let socketPath = "/tmp/openburnbar-subscription-\(UUID().uuidString).sock"
        let token = "test-token"
        let firstServer = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: token,
                daemonVersion: "subscription-test",
                startsMissionControlBackgroundLoops: false
            )
        )
        try await firstServer.start()

        let start: BurnBarRPCResponseEnvelope<BurnBarSubscriptionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "subscription-start-1",
                method: .subscriptionStart,
                authToken: token,
                params: BurnBarSubscriptionStartRequest(topic: .daemonHealth)
            ),
            socketPath: socketPath
        )

        let firstResponse = try XCTUnwrap(start.result)
        XCTAssertNil(start.error)
        XCTAssertEqual(firstResponse.topic, .daemonHealth)
        XCTAssertEqual(firstResponse.firstSnapshot.seq, 1)
        XCTAssertEqual(firstResponse.disconnected, true)
        XCTAssertEqual(firstResponse.degradation?.code, "long_poll_single_response")

        let resume: BurnBarRPCResponseEnvelope<BurnBarSubscriptionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "subscription-resume-1",
                method: .subscriptionResume,
                authToken: token,
                params: BurnBarSubscriptionResumeRequest(
                    subscriptionID: firstResponse.subscriptionID,
                    topic: .daemonHealth,
                    afterSeq: firstResponse.firstSnapshot.seq
                )
            ),
            socketPath: socketPath
        )
        let resumedResponse = try XCTUnwrap(resume.result)
        XCTAssertEqual(resumedResponse.firstSnapshot.seq, 2)
        XCTAssertEqual(resumedResponse.recoveredAfterRestart, false)

        await firstServer.stop()

        let restartedServer = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: token,
                daemonVersion: "subscription-test-restarted",
                startsMissionControlBackgroundLoops: false
            )
        )
        try await restartedServer.start()
        addTeardownBlock { await restartedServer.stop() }

        let restartResume: BurnBarRPCResponseEnvelope<BurnBarSubscriptionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "subscription-resume-restart-1",
                method: .subscriptionResume,
                authToken: token,
                params: BurnBarSubscriptionResumeRequest(
                    subscriptionID: firstResponse.subscriptionID,
                    topic: .daemonHealth,
                    afterSeq: resumedResponse.firstSnapshot.seq
                )
            ),
            socketPath: socketPath
        )
        let restartResponse = try XCTUnwrap(restartResume.result)
        XCTAssertEqual(restartResponse.firstSnapshot.seq, 3)
        XCTAssertEqual(restartResponse.recoveredAfterRestart, true)
        XCTAssertEqual(restartResponse.degradation?.code, "long_poll_reacquire_after_restart")
    }

    func testRunSubscriptionRequiresRunScope() async throws {
        let socketPath = "/tmp/openburnbar-subscription-negative-\(UUID().uuidString).sock"
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            )
        )
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarEmptyResult> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "subscription-run-missing-scope",
                method: .subscriptionStart,
                authToken: "test-token",
                params: BurnBarSubscriptionStartRequest(topic: .run)
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.internalError)
        XCTAssertEqual(response.error?.message.contains("run subscriptions require runID and clientID"), true)
    }

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, streamSocketType, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }
        configureNoSigPipe(for: fileDescriptor)

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
        }

        let payload = try JSONEncoder().encode(envelope) + Data([0x0A])
        try writeAll(payload, to: fileDescriptor)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            guard bytesRead >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 { break }
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }
        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }
        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                #if os(Linux)
                let wrote = Glibc.send(fileDescriptor, baseAddress.advanced(by: offset), remaining, Int32(MSG_NOSIGNAL))
                #else
                let wrote = write(fileDescriptor, baseAddress.advanced(by: offset), remaining)
                #endif
                guard wrote > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                remaining -= wrote
                offset += wrote
            }
        }
    }

    private func configureNoSigPipe(for fileDescriptor: Int32) {
        #if os(Linux)
        _ = fileDescriptor
        #else
        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        #endif

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        return address
    }

    private var streamSocketType: Int32 {
        #if os(Linux)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }
}
