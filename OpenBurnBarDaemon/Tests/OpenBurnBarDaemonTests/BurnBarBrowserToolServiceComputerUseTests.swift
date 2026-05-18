import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarBrowserToolServiceComputerUseTests: XCTestCase {
    func testPlaywrightGotoDispatchesThroughInteractiveExecutor() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-browser-cu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let recorder = PlaywrightCallRecorder()

        let service = BurnBarBrowserToolService(
            fileURL: rootURL.appendingPathComponent("browser-tooling.json"),
            locateExecutable: { executable in
                switch executable {
                case "playwright": return "/usr/local/bin/playwright"
                case "node": return "/usr/local/bin/node"
                default: return nil
                }
            },
            playwrightExecutor: { action, arguments in
                recorder.record(action: action, arguments: arguments)
                return OpenBurnBarPlaywrightDriver.Response(
                    id: 7,
                    ok: true,
                    result: .object([
                        "kind": .string("goto"),
                        "url": .string(arguments.url ?? ""),
                        "finalURL": .string("https://example.com/dashboard"),
                        "status": .number(200)
                    ]),
                    error: nil,
                    elapsedMillis: 42
                )
            },
            logger: BurnBarDaemonLogger(category: "browser-cu-tests")
        )

        _ = try await service.update(BurnBarBrowserToolingUpdateRequest(
            preferredEngine: .playwright,
            allowExternalNavigation: true,
            enginePreferences: [
                BurnBarBrowserEnginePreference(kind: .systemBrowser, isEnabled: true),
                BurnBarBrowserEnginePreference(kind: .urlSession, isEnabled: true),
                BurnBarBrowserEnginePreference(kind: .playwright, isEnabled: true),
                BurnBarBrowserEnginePreference(kind: .lightpanda, isEnabled: false)
            ]
        ))

        let response = try await service.performAction(BurnBarBrowserActionRequest(
            action: .goto,
            url: "https://example.com",
            preferredEngine: .playwright,
            arguments: BurnBarBrowserActionArguments(url: "https://example.com/dashboard")
        ))

        XCTAssertEqual(recorder.action, .goto)
        XCTAssertEqual(recorder.arguments?.url, "https://example.com/dashboard")
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.engine, .playwright)
        XCTAssertTrue(response.summary.contains("https://example.com/dashboard"))
        XCTAssertEqual(response.detail, "42 ms")
    }

    func testInteractiveBrowserActionsRequirePlaywrightEngine() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-browser-cu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let service = BurnBarBrowserToolService(
            fileURL: rootURL.appendingPathComponent("browser-tooling.json"),
            fetcher: { url in
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("<html></html>".utf8), response)
            },
            logger: BurnBarDaemonLogger(category: "browser-cu-tests")
        )

        let response = try await service.performAction(BurnBarBrowserActionRequest(
            action: .click,
            url: "https://example.com",
            preferredEngine: .urlSession,
            arguments: BurnBarBrowserActionArguments(selector: "button")
        ))

        XCTAssertEqual(response.ok, false)
        XCTAssertTrue(response.summary.contains("cannot run interactive browser actions"))
        XCTAssertTrue(response.detail?.contains("Choose Playwright") == true)
    }
}

private final class PlaywrightCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAction: BurnBarBrowserActionKind?
    private var storedArguments: BurnBarBrowserActionArguments?

    var action: BurnBarBrowserActionKind? {
        lock.withLock { storedAction }
    }

    var arguments: BurnBarBrowserActionArguments? {
        lock.withLock { storedArguments }
    }

    func record(action: BurnBarBrowserActionKind, arguments: BurnBarBrowserActionArguments) {
        lock.withLock {
            storedAction = action
            storedArguments = arguments
        }
    }
}
