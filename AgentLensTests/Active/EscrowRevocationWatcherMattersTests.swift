#if canImport(AppKit)
import Foundation
import XCTest
@testable import OpenBurnBar

/// T2 try?-error-swallow remediation for `EscrowRevocationWatcher`.
///
/// The watcher resolves the revoked device's paired peer node id and hands it to
/// `ComputerUseSessionCoordinator.revokeEscrowDevice`, which tears down an
/// in-flight live session ONLY when that peer matches the active session. The
/// original `try? await ...getDocument()` collapsed a Firestore fault to `nil`,
/// which is indistinguishable from "this device has no peer" — silently failing
/// open on the live-session teardown lane.
///
/// These tests pin the fixed behavior:
///  * a transient fetch fault is retried and recovered (no spurious skip),
///  * a peer resolved directly or via the authority mapping is delivered,
///  * a genuine absence delivers `nil` and is recorded as handled,
///  * an UNRECOVERABLE fetch fault never marks the device handled, so a later
///    snapshot re-attempts resolution and can still tear the session down.
@MainActor
final class EscrowRevocationWatcherMattersTests: XCTestCase {
    private struct FetchFault: Error {}

    /// Records every `onRevoked(deviceId:peerNodeId:)` callback in order.
    @MainActor
    private final class RevocationRecorder {
        private(set) var calls: [(deviceId: String, peerNodeId: String?)] = []
        func handler(_ deviceId: String, _ peerNodeId: String?) async {
            calls.append((deviceId, peerNodeId))
        }
    }

    /// Counts authority-fetch invocations and replays a scripted result/throw.
    @MainActor
    private final class AuthorityFetchProbe {
        private(set) var attempts = 0
        /// `nil` element => throw; non-nil => return that optional peer.
        private var script: [String??]
        private let defaultResult: String??

        init(script: [String??], defaultResult: String?? = .some(.none)) {
            self.script = script
            self.defaultResult = defaultResult
        }

        func next() throws -> String? {
            attempts += 1
            let element: String?? = script.isEmpty ? defaultResult : script.removeFirst()
            guard let value = element else { throw FetchFault() }
            return value
        }
    }

    private func makeWatcher(
        recorder: RevocationRecorder,
        provider: @escaping @Sendable (_ uid: String, _ deviceId: String) async throws -> String?,
        maxAttempts: Int = 3
    ) -> EscrowRevocationWatcher {
        EscrowRevocationWatcher(
            firestoreProvider: { fatalError("Firestore must not be touched in unit tests") },
            authorityPeerNodeIdProvider: provider,
            peerFetchMaxAttempts: maxAttempts,
            peerFetchRetryDelay: .zero,
            onRevoked: { deviceId, peerNodeId in await recorder.handler(deviceId, peerNodeId) }
        )
    }

    // MARK: - Direct peer on the escrow doc short-circuits the fetch

    func test_directPeerNodeIdIsResolvedWithoutTouchingAuthorityFetch() async {
        let recorder = RevocationRecorder()
        let probe = AuthorityFetchProbe(script: [])
        let watcher = makeWatcher(recorder: recorder) { _, deviceId in
            try await MainActor.run { try probe.next() } ?? deviceId
        }

        await watcher.processRevokedDevice(
            uid: "uid-1",
            deviceId: "device-A",
            deviceData: ["peerNodeId": "peer-direct"]
        )

        XCTAssertEqual(probe.attempts, 0, "A direct peer must short-circuit the authority fetch")
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.deviceId, "device-A")
        XCTAssertEqual(recorder.calls.first?.peerNodeId, "peer-direct")
    }

    // MARK: - Authority mapping resolves the peer

    func test_peerResolvedFromAuthorityMappingIsDelivered() async {
        let recorder = RevocationRecorder()
        let watcher = makeWatcher(recorder: recorder) { _, _ in "peer-from-authority" }

        await watcher.processRevokedDevice(uid: "uid-1", deviceId: "device-B", deviceData: [:])

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.peerNodeId, "peer-from-authority")
    }

    // MARK: - Genuine absence delivers nil and is recorded handled (idempotent)

    func test_genuineAbsenceDeliversNilAndIsNotReprocessed() async {
        let recorder = RevocationRecorder()
        let probe = AuthorityFetchProbe(script: [.some(.none)], defaultResult: .some(.none))
        let watcher = makeWatcher(recorder: recorder) { _, _ in
            try await MainActor.run { try probe.next() }
        }

        await watcher.processRevokedDevice(uid: "uid-1", deviceId: "device-C", deviceData: [:])
        // A second snapshot for the same device must NOT re-fire: a confirmed
        // absence is a definitive resolution and the device is recorded handled.
        await watcher.processRevokedDevice(uid: "uid-1", deviceId: "device-C", deviceData: [:])

        XCTAssertEqual(recorder.calls.count, 1, "A definitively-resolved device must not re-fire")
        XCTAssertNil(recorder.calls.first?.peerNodeId)
        XCTAssertEqual(probe.attempts, 1, "No retries on a clean no-peer read")
    }

    // MARK: - Transient fault is retried and recovered (no spurious skip)

    func test_transientFetchFaultIsRetriedThenResolves() async {
        let recorder = RevocationRecorder()
        // Throw twice, then succeed with a real peer — within the 3-attempt budget.
        let probe = AuthorityFetchProbe(script: [.none, .none, .some("peer-after-retry")])
        let watcher = makeWatcher(recorder: recorder) { _, _ in
            try await MainActor.run { try probe.next() }
        }

        await watcher.processRevokedDevice(uid: "uid-1", deviceId: "device-D", deviceData: [:])

        XCTAssertEqual(probe.attempts, 3, "The fault must be retried up to the attempt budget")
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(
            recorder.calls.first?.peerNodeId,
            "peer-after-retry",
            "A recovered fetch must deliver the real peer so the session can be torn down"
        )
    }

    // MARK: - Unrecoverable fault FAILS CLOSED: never recorded, re-attempted later

    func test_unrecoverableFetchFaultDoesNotMarkDeviceHandledAndReResolvesLater() async {
        let recorder = RevocationRecorder()
        // First call: every attempt throws (exhausts the budget) => unresolvable.
        // Second call (a later snapshot): the transient fault has cleared and the
        // real peer resolves — the in-flight session can now be torn down.
        let probe = AuthorityFetchProbe(
            script: [.none, .none, .none, .some("peer-recovered-next-snapshot")],
            defaultResult: .some("peer-recovered-next-snapshot")
        )
        let watcher = makeWatcher(recorder: recorder) { _, _ in
            try await MainActor.run { try probe.next() }
        }

        await watcher.processRevokedDevice(uid: "uid-1", deviceId: "device-E", deviceData: [:])

        // The grant-path revocation still fires immediately (coordinator fails
        // that lane closed regardless of peer), but with no resolved peer yet.
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertNil(
            recorder.calls.first?.peerNodeId,
            "An unresolvable fetch must NOT fabricate a peer"
        )
        XCTAssertEqual(probe.attempts, 3, "All attempts in the budget are spent before giving up")

        // CRITICAL fail-closed guarantee: the device was NOT recorded handled, so
        // the next snapshot re-attempts resolution and now delivers the real peer.
        await watcher.processRevokedDevice(uid: "uid-1", deviceId: "device-E", deviceData: [:])

        XCTAssertEqual(recorder.calls.count, 2, "An unresolved device must be re-actioned on the next snapshot")
        XCTAssertEqual(
            recorder.calls.last?.peerNodeId,
            "peer-recovered-next-snapshot",
            "Re-resolution after the fault clears must hand the peer to the teardown lane"
        )
    }

    // MARK: - Contrast: the OLD try? behavior would have silently skipped teardown

    func test_faultThenRecoveryProvesNoSilentFailOpenOnTeardownLane() async {
        let recorder = RevocationRecorder()
        // Budget of 1 => a single throw is immediately unresolvable (mirrors the
        // old `try?` which gave a single attempt and swallowed the error to nil).
        let probe = AuthorityFetchProbe(
            script: [.none, .some("peer-eventually")],
            defaultResult: .some("peer-eventually")
        )
        let watcher = makeWatcher(recorder: recorder, provider: { _, _ in
            try await MainActor.run { try probe.next() }
        }, maxAttempts: 1)

        await watcher.processRevokedDevice(uid: "uid-1", deviceId: "device-F", deviceData: [:])
        XCTAssertNil(recorder.calls.first?.peerNodeId)

        // Unlike the old `try?`, the device is eligible for re-resolution, so the
        // revoked peer's live session is not permanently spared.
        await watcher.processRevokedDevice(uid: "uid-1", deviceId: "device-F", deviceData: [:])
        XCTAssertEqual(recorder.calls.last?.peerNodeId, "peer-eventually")
    }
}
#endif
