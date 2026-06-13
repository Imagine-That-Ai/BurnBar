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
        XCTAssertTrue(response.ok)
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

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.summary.contains("cannot run interactive browser actions"))
        XCTAssertEqual(response.detail?.contains("Choose Playwright"), true)
    }

    func testRejectsNonHttpBrowserURLs() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-browser-cu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let service = BurnBarBrowserToolService(
            fileURL: rootURL.appendingPathComponent("browser-tooling.json"),
            logger: BurnBarDaemonLogger(category: "browser-cu-tests")
        )

        for blocked in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi"] {
            do {
                _ = try await service.performAction(BurnBarBrowserActionRequest(
                    action: .fetchDocument,
                    url: blocked,
                    preferredEngine: .urlSession,
                    arguments: BurnBarBrowserActionArguments(url: blocked)
                ))
                XCTFail("Expected rejection for \(blocked)")
            } catch {
                let message = (error as NSError).localizedDescription.lowercased()
                XCTAssertTrue(
                    message.contains("http") || message.contains("invalid"),
                    "Unexpected error for \(blocked): \(message)"
                )
            }
        }
    }

    func testBrowserTargetPolicyRejectsLocalPrivateAndMetadataHosts() throws {
        let blocked = [
            "http://localhost:3000",
            "http://127.0.0.1:11434/api/tags",
            "http://10.0.0.4",
            "http://172.20.1.8",
            "http://192.168.1.2",
            "http://169.254.169.254/latest/meta-data",
            "http://2130706433/",
            "http://0x7f000001/",
            "http://0177.0.0.1/",
            "http://127.1/",
            "http://0300.0250.0001.0001/",
            "http://[::1]/",
            "http://[fe80::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://[::127.0.0.1]/",
            "http://metadata.google.internal/computeMetadata/v1",
            "file:///etc/passwd"
        ]

        for url in blocked {
            XCTAssertThrowsError(try OpenBurnBarBrowserTargetPolicy.validatedURL(url), url)
        }

        XCTAssertNoThrow(try OpenBurnBarBrowserTargetPolicy.validatedURL("https://example.com/dashboard"))
        XCTAssertNoThrow(try OpenBurnBarBrowserTargetPolicy.validatedURL("data:text/html,ok", allowDataURL: true))
        XCTAssertThrowsError(try OpenBurnBarBrowserTargetPolicy.validatedURL("data:text/html,ok"))
    }

    func testRedirectGuardRejectsBlockedRedirectTargetsBeforeFollow() {
        let guardDelegate = BurnBarBrowserRedirectGuard()
        let originalURL = URL(string: "https://example.com/start")!
        let blockedRequest = URLRequest(url: URL(string: "http://169.254.169.254/latest/meta-data")!)
        let task = URLSession.shared.dataTask(with: originalURL)
        defer { task.cancel() }
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": blockedRequest.url!.absoluteString]
        )!

        let redirectRecorder = RedirectRequestRecorder()
        guardDelegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: blockedRequest
        ) { request in
            redirectRecorder.record(request)
        }

        XCTAssertNil(redirectRecorder.request)
    }

    func testRedirectGuardAllowsPublicRedirectTargets() {
        let guardDelegate = BurnBarBrowserRedirectGuard()
        let originalURL = URL(string: "https://example.com/start")!
        let publicRequest = URLRequest(url: URL(string: "https://docs.example.com/page")!)
        let task = URLSession.shared.dataTask(with: originalURL)
        defer { task.cancel() }
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": publicRequest.url!.absoluteString]
        )!

        let redirectRecorder = RedirectRequestRecorder()
        guardDelegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: publicRequest
        ) { request in
            redirectRecorder.record(request)
        }

        XCTAssertEqual(redirectRecorder.request?.url, publicRequest.url)
    }

    func testPlaywrightGotoRejectsBlockedTargetsBeforeExecutorDispatch() async throws {
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
                    id: 1,
                    ok: true,
                    result: .object(["url": .string(arguments.url ?? "")]),
                    error: nil,
                    elapsedMillis: 1
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

        do {
            _ = try await service.performAction(BurnBarBrowserActionRequest(
                action: .goto,
                url: "http://169.254.169.254/latest/meta-data",
                preferredEngine: .playwright,
                arguments: BurnBarBrowserActionArguments(url: "http://169.254.169.254/latest/meta-data")
            ))
            XCTFail("Expected blocked metadata target to be rejected")
        } catch {
            XCTAssertTrue((error as NSError).localizedDescription.contains("blocked local"))
        }

        XCTAssertNil(recorder.action)
        XCTAssertNil(recorder.arguments)
    }
}

private final class RedirectRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    func record(_ request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        capturedRequest = request
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
