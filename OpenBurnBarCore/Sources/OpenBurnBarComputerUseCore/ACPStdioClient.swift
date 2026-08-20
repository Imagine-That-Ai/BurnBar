import Foundation

/// ACP JSON-RPC client over stdio. Maps `session/request_permission`
/// onto the existing approval plane. Refuses `allow_always` and auto-accept modes.
/// Never execs `grok agent stdio` / `kimi acp` as an argv-only hang.
public enum ACPStdioClient {
    public struct Error: Swift.Error, Equatable {
        public var code: String
        public var message: String
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public struct PermissionRequest: Equatable, Sendable {
        public var method: String
        public var toolName: String?
        public var rawParams: [String: String]
    }

    public static func refuseAutoAcceptMode(_ mode: String) throws {
        let banned = ["auto", "yolo", "allow_always", "dontAsk", "bypassPermissions", "accept-edits"]
        if banned.contains(mode) {
            throw Error(code: "auto_accept_refused", message: "ACP mode \(mode) is incompatible with daemon-owned approvals.")
        }
    }

    public static func encodeRequest(id: Int, method: String, params: [String: Any]) throws -> Data {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try JSONSerialization.data(withJSONObject: body)
    }

    public static func decodePermissionMethod(_ method: String) -> Bool {
        method == "session/request_permission"
    }

    public static func launchArgv(for runtime: String) -> [String] {
        switch runtime {
        case "grok", "grok-build", "xai", "grok-agent":
            return ["agent", "stdio"]
        case "kimi", "kimi-code", "kimi-cli":
            return ["acp"]
        default:
            return []
        }
    }

    public static func executableName(for runtime: String) -> String? {
        switch runtime {
        case "grok", "grok-build", "xai", "grok-agent":
            return "grok"
        case "kimi", "kimi-code", "kimi-cli":
            return "kimi"
        default:
            return nil
        }
    }

    /// Drive initialize → notifications/initialized → session/new → session/prompt
    /// over NDJSON JSON-RPC. `request_permission` is answered from `onPermission`
    /// (never auto-accept). `interrupt` terminates the child.
    @discardableResult
    public static func runSession(
        executable: String,
        arguments: [String],
        prompt: String,
        extraEnvironment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 180,
        onPermission: @escaping (PermissionRequest) async -> Bool,
        onUpdate: @escaping (String) -> Void = { _ in },
        interruptFlag: () -> Bool = { false }
    ) async throws -> String {
        let banned = CLIArgumentBuilderForbiddenFlags.hits(in: arguments)
        if !banned.isEmpty {
            throw Error(code: "forbidden_flags", message: "ACP argv contains forbidden flags: \(banned.joined(separator: ","))")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        var nextID = 1
        let scanner = LineScanner()
        func write(_ method: String, params: [String: Any], notification: Bool = false) throws {
            var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            if !notification {
                body["id"] = nextID
                nextID += 1
            }
            var data = try JSONSerialization.data(withJSONObject: body)
            data.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: data)
        }

        try write("initialize", params: [
            "protocolVersion": 1,
            "clientInfo": ["name": "OpenBurnBar", "version": "1"],
            "capabilities": ["fs": false, "terminal": false]
        ])
        try write("notifications/initialized", params: [:], notification: true)
        try write("session/new", params: ["cwd": workingDirectory?.path ?? FileManager.default.currentDirectoryPath])

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var sessionID: String?
        var promptSent = false
        var assistant = ""
        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = nil

        while Date() < deadline {
            if interruptFlag() {
                process.terminate()
                throw Error(code: "interrupted", message: "ACP session interrupted.")
            }
            guard let line = scanner.readLine(from: stdoutHandle, until: deadline) else {
                if !process.isRunning { break }
                continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let method = obj["method"] as? String, method == "session/set_mode" {
                let params = obj["params"] as? [String: Any] ?? [:]
                let mode = (params["mode"] as? String) ?? (params["permissionMode"] as? String) ?? ""
                if let reqID = obj["id"] {
                    var response: [String: Any] = ["jsonrpc": "2.0", "id": reqID]
                    do {
                        try refuseAutoAcceptMode(mode)
                        response["result"] = ["mode": mode]
                    } catch {
                        response["error"] = ["code": -32602, "message": "auto-accept mode refused"]
                    }
                    var data = try JSONSerialization.data(withJSONObject: response)
                    data.append(0x0A)
                    try stdin.fileHandleForWriting.write(contentsOf: data)
                }
                continue
            }
            if let method = obj["method"] as? String, decodePermissionMethod(method) {
                let params = obj["params"] as? [String: Any] ?? [:]
                let tool = (params["toolName"] as? String) ?? (params["name"] as? String)
                let allowed = await onPermission(PermissionRequest(method: method, toolName: tool, rawParams: [:]))
                if let reqID = obj["id"] {
                    var response: [String: Any] = [
                        "jsonrpc": "2.0",
                        "id": reqID,
                        "result": [
                            "outcome": allowed ? "allow_once" : "deny",
                            "optionId": allowed ? "allow-once" : "reject"
                        ]
                    ]
                    var data = try JSONSerialization.data(withJSONObject: response)
                    data.append(0x0A)
                    try stdin.fileHandleForWriting.write(contentsOf: data)
                }
                continue
            }
            if let result = obj["result"] as? [String: Any] {
                if let sid = result["sessionId"] as? String ?? result["sessionID"] as? String {
                    sessionID = sid
                }
                if let stop = result["stopReason"] as? String, stop != "end_turn" {
                    onUpdate(stop)
                }
                if let text = result["text"] as? String {
                    assistant += text
                    onUpdate(text)
                }
            }
            if let method = obj["method"] as? String, method == "session/update" {
                if let params = obj["params"] as? [String: Any] {
                    if let chunk = params["text"] as? String ?? nestedText(params) {
                        assistant += chunk
                        onUpdate(chunk)
                    }
                }
            }
            if sessionID != nil && !promptSent {
                promptSent = true
                try write("session/prompt", params: [
                    "sessionId": sessionID as Any,
                    "prompt": [["type": "text", "text": prompt]]
                ])
            }
            if promptSent, let result = obj["result"] as? [String: Any], result["stopReason"] != nil {
                break
            }
        }
        if process.isRunning { process.terminate() }
        if assistant.isEmpty && sessionID == nil {
            throw Error(code: "acp_handshake_failed", message: "ACP stdio handshake produced no session.")
        }
        return assistant
    }

    private static func nestedText(_ params: [String: Any]) -> String? {
        if let update = params["update"] as? [String: Any] {
            if let text = update["text"] as? String { return text }
            if let content = update["content"] as? [String: Any], let text = content["text"] as? String {
                return text
            }
        }
        return nil
    }

    /// Persistent NDJSON scanner. Bytes after the first newline stay in
    /// `leftover` so a single `availableData` chunk with two JSON objects
    /// still yields both lines. Mutated only on the stdio read hop.
    /// sendable-allowlist: process-handle
    final class LineScanner: @unchecked Sendable {
        private var leftover = Data()

        func readLine(from handle: FileHandle, until deadline: Date) -> String? {
            while Date() < deadline {
                if let range = leftover.firstIndex(of: 0x0A) {
                    let line = leftover.subdata(in: leftover.startIndex..<range)
                    leftover.removeSubrange(leftover.startIndex...range)
                    return String(data: line, encoding: .utf8)
                }
                let chunk = handle.availableData
                if chunk.isEmpty {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                leftover.append(chunk)
            }
            return nil
        }

        func feedForTests(_ data: Data) {
            leftover.append(data)
        }

        func drainLineForTests() -> String? {
            guard let range = leftover.firstIndex(of: 0x0A) else { return nil }
            let line = leftover.subdata(in: leftover.startIndex..<range)
            leftover.removeSubrange(leftover.startIndex...range)
            return String(data: line, encoding: .utf8)
        }
    }
}

enum CLIArgumentBuilderForbiddenFlags {
    static func hits(in arguments: [String]) -> [String] {
        let banned = [
            "--always-approve",
            "--yolo",
            "-y",
            "--auto",
            "--dangerously-skip-permissions",
            "--approval-mode=yolo",
            "allow_always",
            "--auto-approve"
        ]
        var hits: [String] = []
        for (index, arg) in arguments.enumerated() {
            if banned.contains(arg) { hits.append(arg) }
            if arg == "--permission-mode", index + 1 < arguments.count {
                let mode = arguments[index + 1]
                if ["auto", "dontAsk", "bypassPermissions", "yolo"].contains(mode) {
                    hits.append("\(arg) \(mode)")
                }
            }
        }
        return hits
    }
}
