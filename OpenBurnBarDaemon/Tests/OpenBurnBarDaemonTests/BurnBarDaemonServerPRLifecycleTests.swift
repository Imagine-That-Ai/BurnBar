import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarDaemon

final class BurnBarDaemonServerTestsPRLifecycle: XCTestCase {
    func testVAL_CROSS_007_DaemonRPCReconcilesPRLifecycleTransitions() async throws {
        let socketPath = makeSocketPath(name: "pr-lifecycle")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath)
        )

        try await server.start()
        defer {
            Task {
                await server.stop()
            }
        }

        let createResponse: BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "mission-create-pr-1",
                method: .missionCreate,
                params: BurnBarMissionCreateRequest(
                    projectSlug: "apollo",
                    title: "Ship PR lifecycle parity",
                    summary: "Ensure PR transitions reconcile across surfaces.",
                    createdBy: "test-suite",
                    recommendation: .review
                )
            ),
            socketPath: socketPath
        )
        let missionID = try XCTUnwrap(createResponse.result?.mission.id)
        let now = Date(timeIntervalSince1970: 1_710_001_000)

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "mission-result-opened-1",
                method: .missionRecordResult,
                params: BurnBarMissionRecordResultRequest(
                    missionID: missionID,
                    result: BurnBarMissionResultSnapshot(
                        id: BurnBarMissionResultID(rawValue: "result-pr-opened"),
                        missionID: missionID,
                        status: .succeeded,
                        summary: "Connector opened PR #42.",
                        createdAt: now,
                        prLinkage: BurnBarPRLinkageSnapshot(
                            repository: "Ajnunezg/BurnBar",
                            prNumberOrID: "42",
                            url: "https://github.com/Ajnunezg/BurnBar/pull/42",
                            state: .opened
                        )
                    )
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>

        let openedMission = try fetchMission(id: missionID, socketPath: socketPath)
        XCTAssertEqual(openedMission.prLinkage?.repository, "Ajnunezg/BurnBar")
        XCTAssertEqual(openedMission.prLinkage?.prNumberOrID, "42")
        XCTAssertEqual(openedMission.prLinkage?.state, .opened)

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "mission-result-merged-1",
                method: .missionRecordResult,
                params: BurnBarMissionRecordResultRequest(
                    missionID: missionID,
                    result: BurnBarMissionResultSnapshot(
                        id: BurnBarMissionResultID(rawValue: "result-pr-merged"),
                        missionID: missionID,
                        status: .succeeded,
                        summary: "Connector reported PR merged.",
                        createdAt: now.addingTimeInterval(30),
                        prLinkage: BurnBarPRLinkageSnapshot(
                            repository: "Ajnunezg/BurnBar",
                            prNumberOrID: "42",
                            url: "https://github.com/Ajnunezg/BurnBar/pull/42",
                            state: .merged,
                            mergeCommitSHA: "abc123def",
                            mergedAt: now.addingTimeInterval(30)
                        )
                    )
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "mission-result-closed-1",
                method: .missionRecordResult,
                params: BurnBarMissionRecordResultRequest(
                    missionID: missionID,
                    result: BurnBarMissionResultSnapshot(
                        id: BurnBarMissionResultID(rawValue: "result-pr-closed"),
                        missionID: missionID,
                        status: .succeeded,
                        summary: "Connector reported PR closed event after merge.",
                        createdAt: now.addingTimeInterval(60),
                        prLinkage: BurnBarPRLinkageSnapshot(
                            repository: "Ajnunezg/BurnBar",
                            prNumberOrID: "42",
                            url: "https://github.com/Ajnunezg/BurnBar/pull/42",
                            state: .closed,
                            closedAt: now.addingTimeInterval(60)
                        )
                    )
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>

        let reconciledMission = try fetchMission(id: missionID, socketPath: socketPath)
        XCTAssertEqual(reconciledMission.prLinkage?.state, .merged)
        XCTAssertEqual(reconciledMission.prLinkage?.mergeCommitSHA, "abc123def")
        XCTAssertEqual(reconciledMission.prLinkage?.prNumberOrID, "42")
        XCTAssertEqual(reconciledMission.metadata["pr_state"], .string("merged"))
        XCTAssertEqual(reconciledMission.metadata["pr_repository"], .string("Ajnunezg/BurnBar"))
    }

    private func fetchMission(
        id: BurnBarMissionID,
        socketPath: String
    ) throws -> BurnBarMissionSnapshot {
        let response: BurnBarRPCResponseEnvelope<BurnBarMissionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "mission-get-\(id.rawValue)",
                method: .missionGet,
                params: BurnBarMissionGetRequest(missionID: id)
            ),
            socketPath: socketPath
        )
        return try XCTUnwrap(response.result?.mission)
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/openburnbar-daemon-tests-\(name)-\(UUID().uuidString).sock"
    }

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

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

        let encoder = JSONEncoder()
        let payload = try encoder.encode(envelope) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var bytesRemaining = rawBuffer.count
            var offset = 0

            while bytesRemaining > 0 {
                let pointer = baseAddress.advanced(by: offset)
                let bytesWritten = write(fileDescriptor, pointer, bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A {
                break
            }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }

        let decoder = JSONDecoder()
        return try decoder.decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
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
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        return address
    }
}
