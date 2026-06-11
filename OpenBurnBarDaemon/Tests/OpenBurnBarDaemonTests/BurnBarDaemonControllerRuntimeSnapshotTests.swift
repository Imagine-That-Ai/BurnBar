import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarDaemon

/// End-to-end coverage for the aggregated controller-runtime RPC
/// (`daemon.controller.runtime_snapshot`) and the runtime snapshot embedded
/// in controller mutation responses — the daemon half of perf finding
/// macos-007 (docs/architecture/macos-performance.md §16). The aggregated
/// answer must stay byte-equivalent to the legacy per-list RPCs it
/// replaces.
final class BurnBarDaemonControllerRuntimeSnapshotTests: XCTestCase {

    func testAggregatedSnapshotMatchesPerListRPCs_andMutationsEmbedIt() async throws {
        let socketPath = makeSocketPath(name: "runtime-snapshot")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            )
        )

        try await server.start()
        defer {
            Task {
                await server.stop()
            }
        }

        let now = Date(timeIntervalSince1970: 1_710_002_000)
        let questionID = BurnBarQuestionID(rawValue: "question-rt-1")
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "question-create-rt-1",
                method: .questionCreate,
                authToken: "test-token",
                params: BurnBarQuestionCreateRequest(
                    question: BurnBarPendingQuestionSnapshot(
                        id: questionID,
                        projectSlug: "apollo",
                        title: "Approve the rollout?",
                        prompt: "Continue with the rollout?",
                        status: .pending,
                        priority: .high,
                        askedAt: now
                    )
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarQuestionResponse>

        let followupID = BurnBarFollowupID(rawValue: "followup-rt-1")
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "followup-create-rt-1",
                method: .followupCreate,
                authToken: "test-token",
                params: BurnBarFollowupCreateRequest(
                    followup: BurnBarFollowupSnapshot(
                        id: followupID,
                        projectSlug: "apollo",
                        title: "Check rollout health",
                        summary: "Verify the rollout after approval.",
                        status: .open,
                        kind: .controllerNudge,
                        createdAt: now
                    )
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>

        // ── Aggregated RPC returns the same rows the per-list RPCs do ──
        let aggregated: BurnBarRPCResponseEnvelope<BurnBarControllerRuntimeSnapshotResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "runtime-snapshot-1",
                method: .controllerRuntimeSnapshot,
                authToken: "test-token",
                params: BurnBarControllerRuntimeSnapshotRequest()
            ),
            socketPath: socketPath
        )
        let snapshot = try XCTUnwrap(aggregated.result?.snapshot)

        let perListQuestions: BurnBarRPCResponseEnvelope<BurnBarQuestionsListResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "questions-list-rt-1",
                method: .questionsList,
                authToken: "test-token",
                params: BurnBarQuestionsListRequest(
                    projectSlug: nil,
                    statuses: BurnBarPendingQuestionStatus.allCases
                )
            ),
            socketPath: socketPath
        )
        let perListFollowups: BurnBarRPCResponseEnvelope<BurnBarFollowupsListResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "followups-list-rt-1",
                method: .followupsList,
                authToken: "test-token",
                params: BurnBarFollowupsListRequest(
                    projectSlug: nil,
                    statuses: BurnBarFollowupStatus.allCases
                )
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(snapshot.questions, perListQuestions.result?.questions)
        XCTAssertEqual(snapshot.followups, perListFollowups.result?.followups)
        XCTAssertTrue(snapshot.questions.contains { $0.id == questionID })
        XCTAssertTrue(snapshot.followups.contains { $0.id == followupID })
        XCTAssertGreaterThanOrEqual(snapshot.summary.counts.pendingQuestionCount, 1)

        // ── Mutations embed the refreshed runtime ──
        let answered: BurnBarRPCResponseEnvelope<BurnBarQuestionAnswerResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "question-answer-rt-1",
                method: .questionAnswer,
                authToken: "test-token",
                params: BurnBarQuestionAnswerRequest(
                    questionID: questionID,
                    answeredBy: "operator",
                    answer: "Proceed."
                )
            ),
            socketPath: socketPath
        )
        let answeredSnapshot = try XCTUnwrap(
            answered.result?.runtimeSnapshot,
            "questionAnswer must embed the post-mutation runtime snapshot"
        )
        XCTAssertEqual(
            answeredSnapshot.questions.first { $0.id == questionID }?.status,
            .answered
        )

        let done: BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "followup-done-rt-1",
                method: .followupDone,
                authToken: "test-token",
                params: BurnBarFollowupDoneRequest(followupID: followupID, actor: "operator")
            ),
            socketPath: socketPath
        )
        let doneSnapshot = try XCTUnwrap(
            done.result?.runtimeSnapshot,
            "followupDone must embed the post-mutation runtime snapshot"
        )
        XCTAssertEqual(
            doneSnapshot.followups.first { $0.id == followupID }?.status,
            .done
        )
    }

    // MARK: - Socket plumbing (mirrors BurnBarDaemonServerTestsPRLifecycle)

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
