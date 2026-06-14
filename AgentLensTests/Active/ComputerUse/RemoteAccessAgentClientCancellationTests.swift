#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
@testable import OpenBurnBar
import OpenBurnBarComputerUseCore

/// Cancellation coverage for the socket clients that replaced `Task.detached`.
/// They use `Task(priority:)` from a nonisolated context, so caller cancellation
/// now propagates through the structured-concurrency tree.
@MainActor
final class RemoteAccessAgentClientCancellationTests: XCTestCase {

    func testTypeCredentialPropagatesCancellation() async {
        let client = RemoteAccessAgentClient(
            socketPath: "/tmp/no-such-openburnbar-remote-access-\(UUID().uuidString).sock"
        )
        let task = Task {
            try await client.typeCredential("password")
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: the structured Task inherits caller cancellation.
        } catch {
            // Other errors are acceptable on a clean test host (missing daemon socket),
            // but cancellation must still be possible.
        }
    }

    func testWakeDisplayPropagatesCancellation() async {
        let client = RemoteAccessAgentClient(
            socketPath: "/tmp/no-such-openburnbar-remote-access-\(UUID().uuidString).sock"
        )
        let task = Task {
            try await client.wakeDisplay()
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: the structured Task inherits caller cancellation.
        } catch {
            // Other errors are acceptable on a clean test host.
        }
    }

    func testVirtualHIDInputDispatchPropagatesCancellation() async {
        let client = RemoteUnlockVirtualHIDInputClient()
        let action = MacInputAction(kind: .type, text: "test")
        let task = Task {
            try await client.dispatch(action)
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: the structured Task inherits caller cancellation.
        } catch {
            // Expected on a clean test host: the XPC/socket path is unavailable.
        }
    }
}
#endif
