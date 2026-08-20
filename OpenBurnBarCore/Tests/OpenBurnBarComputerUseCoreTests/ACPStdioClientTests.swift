import XCTest
@testable import OpenBurnBarComputerUseCore

final class ACPStdioClientTests: XCTestCase {
    func testGrokAndKimiLaunchArgvMatchDecisionRecord() {
        XCTAssertEqual(ACPStdioClient.launchArgv(for: "grok"), ["agent", "stdio"])
        XCTAssertEqual(ACPStdioClient.launchArgv(for: "grok-build"), ["agent", "stdio"])
        XCTAssertEqual(ACPStdioClient.launchArgv(for: "kimi"), ["acp"])
        XCTAssertEqual(ACPStdioClient.launchArgv(for: "kimi-cli"), ["acp"])
        XCTAssertEqual(ACPStdioClient.launchArgv(for: "agy"), [])
    }

    func testExecutableNameForACPRuntimes() {
        XCTAssertEqual(ACPStdioClient.executableName(for: "grok"), "grok")
        XCTAssertEqual(ACPStdioClient.executableName(for: "xai"), "grok")
        XCTAssertEqual(ACPStdioClient.executableName(for: "kimi-code"), "kimi")
        XCTAssertNil(ACPStdioClient.executableName(for: "hermes"))
    }

    func testRefuseAutoAcceptModes() {
        for mode in ["yolo", "allow_always", "auto", "dontAsk", "bypassPermissions", "accept-edits"] {
            XCTAssertThrowsError(try ACPStdioClient.refuseAutoAcceptMode(mode), mode)
        }
        XCTAssertNoThrow(try ACPStdioClient.refuseAutoAcceptMode("default"))
    }

    func testEncodeRequestAndPermissionMethod() throws {
        let data = try ACPStdioClient.encodeRequest(id: 7, method: "session/new", params: ["cwd": "/tmp"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj["id"] as? Int, 7)
        XCTAssertEqual(obj["method"] as? String, "session/new")
        XCTAssertTrue(ACPStdioClient.decodePermissionMethod("session/request_permission"))
        XCTAssertFalse(ACPStdioClient.decodePermissionMethod("session/prompt"))
    }

    func testForbiddenFlagsFailClosedBeforeLaunch() async {
        do {
            _ = try await ACPStdioClient.runSession(
                executable: "/usr/bin/true",
                arguments: ["--yolo"],
                prompt: "hi",
                timeoutSeconds: 1,
                onPermission: { _ in false }
            )
            XCTFail("forbidden flags must throw")
        } catch let error as ACPStdioClient.Error {
            XCTAssertEqual(error.code, "forbidden_flags")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(
            CLIArgumentBuilderForbiddenFlags.hits(in: ["--permission-mode", "yolo"]),
            ["--permission-mode yolo"]
        )
        XCTAssertEqual(CLIArgumentBuilderForbiddenFlags.hits(in: ["--yolo"]), ["--yolo"])
    }

    func testHandshakeFailureWhenChildExits() async {
        do {
            _ = try await ACPStdioClient.runSession(
                executable: "/usr/bin/true",
                arguments: [],
                prompt: "hi",
                timeoutSeconds: 2,
                onPermission: { _ in true }
            )
            XCTFail("empty handshake must throw")
        } catch let error as ACPStdioClient.Error {
            XCTAssertEqual(error.code, "acp_handshake_failed")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testInterruptTerminatesBeforeHandshake() async {
        do {
            _ = try await ACPStdioClient.runSession(
                executable: "/bin/sleep",
                arguments: ["5"],
                prompt: "hi",
                timeoutSeconds: 5,
                onPermission: { _ in true },
                interruptFlag: { true }
            )
            XCTFail("interrupt must throw")
        } catch let error as ACPStdioClient.Error {
            XCTAssertEqual(error.code, "interrupted")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRunSessionDrivesPermissionModeAndPrompt() async throws {
        let script = """
        import json, sys
        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()
        for raw in sys.stdin:
            msg = json.loads(raw)
            method = msg.get("method")
            mid = msg.get("id")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s1"}})
                send({"jsonrpc": "2.0", "id": 90, "method": "session/set_mode", "params": {"mode": "default"}})
                send({"jsonrpc": "2.0", "id": 91, "method": "session/set_mode", "params": {"mode": "yolo"}})
                send({"jsonrpc": "2.0", "id": 92, "method": "session/request_permission", "params": {"toolName": "bash"}})
            elif method == "session/prompt":
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"text": "hello "}})
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"content": {"text": "world"}}}})
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn", "text": "!"}})
                break
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-mock-\(UUID().uuidString).py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var permissionCalls = 0
        let output = try await ACPStdioClient.runSession(
            executable: "/usr/bin/python3",
            arguments: [url.path],
            prompt: "say hi",
            timeoutSeconds: 8,
            onPermission: { request in
                permissionCalls += 1
                XCTAssertEqual(request.method, "session/request_permission")
                XCTAssertEqual(request.toolName, "bash")
                return true
            }
        )
        XCTAssertEqual(permissionCalls, 1)
        XCTAssertTrue(output.contains("hello"))
        XCTAssertTrue(output.contains("world"))
        XCTAssertTrue(output.contains("!"))
    }

    func testLineScannerKeepsLeftoverAfterFirstNewline() {
        let scanner = ACPStdioClient.LineScanner()
        let chunk = Data("{\"id\":1,\"result\":{\"sessionId\":\"s1\"}}\n{\"id\":2,\"result\":{\"ok\":true}}\n".utf8)
        scanner.feedForTests(chunk)
        XCTAssertEqual(scanner.drainLineForTests(), "{\"id\":1,\"result\":{\"sessionId\":\"s1\"}}")
        XCTAssertEqual(scanner.drainLineForTests(), "{\"id\":2,\"result\":{\"ok\":true}}")
        XCTAssertNil(scanner.drainLineForTests())
    }
}
