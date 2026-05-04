import SwiftUI
import ViewInspector
import XCTest
@testable import OpenBurnBar

@MainActor
final class DataStoreStartupRecoveryViewTests: XCTestCase {
    func test_rendersFailureMessageAndActions() throws {
        let view = makeView()
        let sut = try view.inspect()

        XCTAssertNoThrow(try sut.find(text: "Database needs attention"))
        XCTAssertNoThrow(try sut.find(text: "OpenBurnBar started in recovery mode."))
        XCTAssertNoThrow(try sut.find(text: "Retry"))
        XCTAssertNoThrow(try sut.find(text: "Archive and Reset"))
        XCTAssertNoThrow(try sut.find(text: "Show Support Folder"))
        XCTAssertNoThrow(try sut.find(text: "Copy Diagnostics"))
        XCTAssertNoThrow(try sut.find(text: "Quit"))
    }

    func test_actionButtonsTriggerCallbacks() throws {
        var retry = false
        var reveal = false
        var copy = false
        var quit = false
        let view = makeView(
            onRetry: { retry = true },
            onRevealSupportFolder: { reveal = true },
            onCopyDiagnostics: {
                copy = true
                return true
            },
            onQuit: { quit = true }
        )

        let buttons = try view.inspect().findAll(ViewType.Button.self)
        XCTAssertGreaterThanOrEqual(buttons.count, 5)

        try buttons[0].tap()
        try buttons[2].tap()
        try buttons[3].tap()
        try buttons[4].tap()

        XCTAssertTrue(retry)
        XCTAssertTrue(reveal)
        XCTAssertTrue(copy)
        XCTAssertTrue(quit)
    }

    func test_copyDiagnosticsSuccessFeedbackRenders() throws {
        let view = makeView(initialCopyStatus: .copied)

        XCTAssertNoThrow(try view.inspect().find(text: "Diagnostics copied to the clipboard."))
    }

    func test_copyDiagnosticsFailureFeedbackRenders() throws {
        let view = makeView(initialCopyStatus: .failed)

        XCTAssertNoThrow(try view.inspect().find(text: "Diagnostics could not be copied. Use Show Support Folder instead."))
    }

    func test_loadingStatesChangePrimaryButtonLabels() throws {
        let failure = makeFailure()
        let view = DataStoreStartupRecoveryView(
            failure: failure,
            isRetrying: true,
            isArchivingReset: true,
            actionError: "Reset failed",
            compact: true,
            onRetry: {},
            onRevealSupportFolder: {},
            onArchiveAndReset: {},
            onCopyDiagnostics: { true },
            onQuit: {}
        )
        let sut = try view.inspect()

        XCTAssertNoThrow(try sut.find(text: "Retrying"))
        XCTAssertNoThrow(try sut.find(text: "Archiving"))
        XCTAssertNoThrow(try sut.find(text: "Reset failed"))
    }

    private func makeView(
        initialCopyStatus: DataStoreStartupRecoveryCopyStatus? = nil,
        onRetry: @escaping () -> Void = {},
        onRevealSupportFolder: @escaping () -> Void = {},
        onArchiveAndReset: @escaping () -> Void = {},
        onCopyDiagnostics: @escaping () -> Bool = { true },
        onQuit: @escaping () -> Void = {}
    ) -> DataStoreStartupRecoveryView {
        DataStoreStartupRecoveryView(
            failure: makeFailure(),
            initialCopyStatus: initialCopyStatus,
            onRetry: onRetry,
            onRevealSupportFolder: onRevealSupportFolder,
            onArchiveAndReset: onArchiveAndReset,
            onCopyDiagnostics: onCopyDiagnostics,
            onQuit: onQuit
        )
    }

    private func makeFailure() -> DataStoreStartupFailure {
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: URL(fileURLWithPath: "/tmp/openburnbar-tests"))
        return DataStoreStartupFailure.make(
            error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
                NSLocalizedDescriptionKey: "database disk image is malformed"
            ]),
            paths: paths,
            occurredAt: Date(timeIntervalSince1970: 0),
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
    }
}
