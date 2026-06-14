#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
@testable import OpenBurnBar

/// Cancellation and concurrency coverage for the virtual-HID bridge installer.
/// The installer historically escaped MainActor via `Task.detached`; it now uses
/// a nonisolated helper that creates a structured `Task(priority:)` so blocking
/// I/O runs off the main actor and cancellation propagates naturally.
@MainActor
final class RemoteUnlockBridgeInstallerConcurrencyTests: XCTestCase {

    func testInstallOrRepairRunsOffMainActor() async throws {
        let fileManager = SlowFileManager()
        let installer = RemoteUnlockVirtualHIDBridgeInstaller(fileManager: fileManager)

        let installTask = Task { @MainActor in
            await installer.installOrRepair()
        }

        // Yield enough time for the installer to reach its blocking FileManager call.
        try await Task.sleep(nanoseconds: 50_000_000)

        // While the installer is blocked off-main, the main actor must still be responsive.
        let pong = await MainActor.run { "pong" }
        XCTAssertEqual(pong, "pong")

        fileManager.resume()
        _ = await installTask.result
        XCTAssertFalse(installer.isInstalling)
    }

    func testInstallOrRepairHandlesCallerCancellation() async throws {
        let fileManager = SlowFileManager()
        let installer = RemoteUnlockVirtualHIDBridgeInstaller(fileManager: fileManager)

        let installTask = Task { @MainActor in
            await installer.installOrRepair()
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        installTask.cancel()

        fileManager.resume()

        // The installer is @MainActor and catches errors internally, so the top-level
        // task completes normally even though the inner work was cancelled.
        await installTask.value
        XCTAssertFalse(installer.isInstalling)
        // Because the synchronous installer body was blocked on the semaphore when
        // cancellation arrived, it still ran to completion once resumed; the cancellation
        // is surfaced as a caught error and recorded as lastError.
        XCTAssertNotNil(installer.lastError)
    }
}

/// A `FileManager` subclass that pretends helper bundles exist and blocks in
/// `createDirectory(atPath:withIntermediateDirectories:)` until
/// `resume()` is called. This lets tests observe the installer's off-main work
/// without touching a real privileged-input bundle.
private final class SlowFileManager: FileManager, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private(set) var createDirectoryCallCount = 0

    override func isExecutableFile(atPath path: String) -> Bool {
        true
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        isDirectory?.pointee = true
        return true
    }

    override func createDirectory(
        atPath path: String,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        createDirectoryCallCount += 1
        semaphore.wait()
        try super.createDirectory(
            atPath: path,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    func resume() {
        semaphore.signal()
    }
}
#endif
