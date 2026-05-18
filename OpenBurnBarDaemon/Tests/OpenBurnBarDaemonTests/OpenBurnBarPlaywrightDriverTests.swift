import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class OpenBurnBarPlaywrightDriverTests: XCTestCase {
    func testDriverMapsBrowserActionsToBridgeRPCParams() async throws {
        let node = try XCTUnwrap(Self.nodeExecutablePath())
        let bridge = try Self.makeEchoBridge()
        let sessionId = ComputerUseSessionID("driver-test-\(UUID().uuidString)")
        let driver = OpenBurnBarPlaywrightDriver(
            configuration: OpenBurnBarPlaywrightDriver.Configuration(
                nodeExecutablePath: node,
                bridgeScriptPath: bridge,
                browserChannel: nil,
                userDataDirectory: nil,
                headless: true,
                perActionTimeoutMillis: 1_234
            ),
            sessionId: sessionId,
            logger: BurnBarDaemonLogger(category: "playwright-driver-tests")
        )

        try await driver.start()

        let click = try await driver.click(selector: "#submit", timeoutMillis: 777)
        try Self.assertEcho(click, method: "click") { params in
            XCTAssertEqual(params["selector"], .string("#submit"))
            XCTAssertEqual(params["timeoutMs"], .number(777))
        }

        let positioned = try await driver.click(selector: nil, positionX: 44, positionY: 55)
        try Self.assertEcho(positioned, method: "click") { params in
            XCTAssertEqual(params["selector"], .null)
            XCTAssertEqual(params["positionX"], .number(44))
            XCTAssertEqual(params["positionY"], .number(55))
            XCTAssertEqual(params["timeoutMs"], .number(1_234))
        }

        let fill = try await driver.fill(selector: "input[name=q]", text: "openburnbar")
        try Self.assertEcho(fill, method: "fill") { params in
            XCTAssertEqual(params["selector"], .string("input[name=q]"))
            XCTAssertEqual(params["text"], .string("openburnbar"))
        }

        let goto = try await driver.goto(url: "https://example.com")
        try Self.assertEcho(goto, method: "goto") { params in
            XCTAssertEqual(params["url"], .string("https://example.com"))
        }

        let key = try await driver.key("Enter", modifiers: ["Meta"])
        try Self.assertEcho(key, method: "key") { params in
            XCTAssertEqual(params["key"], .string("Enter"))
            XCTAssertEqual(params["modifiers"], .array([.string("Meta")]))
        }

        let select = try await driver.select(selector: "#choice", value: "beta")
        try Self.assertEcho(select, method: "select") { params in
            XCTAssertEqual(params["selector"], .string("#choice"))
            XCTAssertEqual(params["value"], .string("beta"))
        }

        let screenshot = try await driver.screenshot(fullPage: true)
        try Self.assertEcho(screenshot, method: "screenshot") { params in
            XCTAssertEqual(params["fullPage"], .bool(true))
        }

        let extract = try await driver.extract(selector: "main")
        try Self.assertEcho(extract, method: "extract") { params in
            XCTAssertEqual(params["selector"], .string("main"))
        }
    }

    private static func assertEcho(
        _ response: OpenBurnBarPlaywrightDriver.Response,
        method expectedMethod: String,
        params assertions: ([String: BurnBarJSONValue]) throws -> Void
    ) throws {
        XCTAssertTrue(response.ok)
        guard case let .object(result)? = response.result else {
            XCTFail("Expected object result, got \(String(describing: response.result))")
            return
        }
        XCTAssertEqual(result["method"], .string(expectedMethod))
        guard case let .object(params)? = result["params"] else {
            XCTFail("Expected object params, got \(String(describing: result["params"]))")
            return
        }
        try assertions(params)
    }

    private static func makeEchoBridge() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-playwright-driver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bridge = directory.appendingPathComponent("echo-bridge.js")
        let script = """
        const readline = require('readline');
        let requestCount = 0;
        console.error('[echo-bridge] ready');
        setTimeout(() => process.exit(0), 2000);
        const rl = readline.createInterface({ input: process.stdin, terminal: false });
        rl.on('line', (line) => {
          requestCount += 1;
          const req = JSON.parse(line);
          setTimeout(() => {
            process.stdout.write(JSON.stringify({
              id: req.id,
              ok: true,
              result: { method: req.method, params: req.params },
              elapsedMillis: 1
            }) + '\\n', () => {
              if (requestCount >= 8) process.exit(0);
            });
          }, 25);
        });
        """
        try script.write(to: bridge, atomically: true, encoding: .utf8)
        return bridge
    }

    private static func nodeExecutablePath() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["NODE_EXECUTABLE"],
            ProcessInfo.processInfo.environment["NODE_BINARY"],
            "/Users/albertonunez/.local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ].compactMap { $0 }

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "node"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
