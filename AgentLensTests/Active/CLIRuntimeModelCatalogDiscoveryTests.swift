import XCTest
@testable import OpenBurnBar

final class CLIRuntimeModelCatalogDiscoveryTests: XCTestCase {

    func test_run_executesCommandAndReturnsOutput() async throws {
        let discovery = CLIRuntimeModelCatalogDiscovery()
        let output = try await discovery.run(
            executable: "/bin/echo",
            arguments: ["catalog-output"],
            timeoutSeconds: 5
        )
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "catalog-output")
    }

    func test_run_propagatesCancellationToChildProcess() async throws {
        let discovery = CLIRuntimeModelCatalogDiscovery()
        let markerName = "openburnbar-runtime-discovery-cancel-test-\(UUID().uuidString)"
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent(markerName)
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let task = Task {
            try await discovery.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 2 && touch \(markerURL.path)"],
                timeoutSeconds: 5
            )
        }

        // Cancel the parent task; the structured-concurrency replacement propagates
        // cancellation to the child process, so the marker should never be written.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation error")
        } catch is CancellationError {
            // Expected: cancellation propagates through the structured Task.
        }

        // Give a brief grace period in case the shell was already about to touch the file.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "Subprocess should be cancelled before writing the marker"
        )
    }
}
