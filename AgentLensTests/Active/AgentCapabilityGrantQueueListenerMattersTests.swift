#if canImport(AppKit)
import FirebaseFirestore
import Foundation
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// The denied-receipt write in `AgentCapabilityGrantQueueListener.process`'s
/// catch path is the authoritative security decision returned to a requesting
/// device. It used to be swallowed by `try?`, so a transient write fault left
/// the request `.queued` with no record and no signal. These tests pin the
/// fixed behavior:
///   1. the denial IS written (correct `.denied` status + `signature_failure`
///      reason at the request's own path), and
///   2. a failing write degrades gracefully (no propagation/crash of the
///      detached process Task) while NEVER falling open into approval.
final class AgentCapabilityGrantQueueListenerMattersTests: XCTestCase {
    /// Records every receipt-write the listener attempts; can be armed to throw
    /// so the catch-path's durable-but-graceful handling is exercised.
    private actor CaptureWriter {
        struct Capture: Sendable {
            let path: String
            let status: String?
            let denialReason: String?
        }

        private(set) var captures: [Capture] = []
        private let shouldThrow: Bool

        init(shouldThrow: Bool) {
            self.shouldThrow = shouldThrow
        }

        /// Records a single write. Only `Sendable` scalars cross the actor
        /// boundary — the `[String: Any]` payload is destructured in the
        /// non-isolated writer closure before it reaches the actor.
        func record(_ capture: Capture) throws {
            captures.append(capture)
            if shouldThrow {
                throw URLError(.notConnectedToInternet)
            }
        }

        func snapshot() -> [Capture] { captures }
    }

    private enum FixturePath {
        static let request = "users/uid-1/agent_capability_grant_requests/req-42"
    }

    private func makeListener(writer: CaptureWriter) -> AgentCapabilityGrantQueueListener {
        AgentCapabilityGrantQueueListener(
            // Provider must never be touched on the receipt-write path: a write
            // resolves through the injected writer, not Firestore.
            firestoreProvider: {
                XCTFail("firestoreProvider must not be used when a receiptWriter is injected")
                return Firestore.firestore()
            },
            receiptWriter: { path, payload in
                // Destructure the non-Sendable payload here (non-isolated), so
                // only Sendable scalars cross into the capture actor.
                let receipt = payload["receipt"] as? [String: Any]
                let capture = CaptureWriter.Capture(
                    path: path,
                    status: payload["status"] as? String,
                    denialReason: receipt?["denialReason"] as? String
                )
                try await writer.record(capture)
            }
        )
    }

    private func requestData() -> [String: Any] {
        [
            "requestId": "req-42",
            "runtime": "hermes",
            "threadId": "thread-7",
            "trustMode": "manual",
            "capabilities": ["filesystem.read"],
            "sourceDeviceId": "device-abc"
        ]
    }

    // MARK: - The denial is actually written (no silent loss)

    func test_writeDenialReceipt_persistsDeniedReceiptAtRequestPath() async throws {
        let writer = CaptureWriter(shouldThrow: false)
        let listener = makeListener(writer: writer)

        await listener.writeDenialReceipt(
            forData: requestData(),
            message: "untrusted controller key",
            to: FixturePath.request
        )

        let captures = await writer.snapshot()
        XCTAssertEqual(captures.count, 1, "the denial must be written exactly once")
        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(capture.path, FixturePath.request)
        XCTAssertEqual(
            capture.status,
            AgentGrantDecisionStatus.denied.rawValue,
            "the security decision communicated back must be a denial"
        )
        XCTAssertEqual(
            capture.denialReason,
            AgentGrantDenialReason.signatureFailure.rawValue,
            "verification failures map to a signature_failure denial"
        )
    }

    // MARK: - A failing write degrades gracefully, never fails open

    func test_writeDenialReceipt_failingWriteDoesNotPropagateAndNeverGrants() async {
        let writer = CaptureWriter(shouldThrow: true)
        let listener = makeListener(writer: writer)

        // The fixed code must NOT swallow blind: it attempts the write, the
        // write throws, and the method returns normally (logging durably)
        // rather than crashing the detached process Task.
        await listener.writeDenialReceipt(
            forData: requestData(),
            message: "decode failure",
            to: FixturePath.request
        )

        let captures = await writer.snapshot()
        XCTAssertEqual(captures.count, 1, "the write must be attempted even when it will fail")
        // Critically: the only payload ever sent is a DENIAL. A lost write
        // withholds approval; it must never emit an applied/queued receipt.
        for capture in captures {
            XCTAssertEqual(capture.status, AgentGrantDecisionStatus.denied.rawValue)
            XCTAssertNotEqual(capture.status, AgentGrantDecisionStatus.applied.rawValue)
        }
    }

    // MARK: - The verified-write path routes through the same seam

    func test_writeDenialReceipt_usesInjectedWriterNotFirestore() async {
        // Guarantees the seam is wired: if production accidentally bypassed the
        // injected writer (e.g. wrote to Firestore directly), the capture stays
        // empty and this fails — the firestoreProvider XCTFail would also fire.
        let writer = CaptureWriter(shouldThrow: false)
        let listener = makeListener(writer: writer)

        await listener.writeDenialReceipt(
            forData: [:],
            message: "empty request",
            to: FixturePath.request
        )

        let captures = await writer.snapshot()
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.status, AgentGrantDecisionStatus.denied.rawValue)
    }
}
#endif
