import Foundation

enum BurnBarCLIComputerUseLiveSurface {
    private static let usageText = """
    Usage:
      openburnbar-cli computer-use live-surface-proof --panic-url URL --media-url URL [--audit-head HASH] [--json]
    """

    static func run(arguments: [String]) throws -> BurnBarCLIInvocationResult {
        guard arguments.first == "live-surface-proof" else {
            throw BurnBarCLIError.missingArgument(usageText)
        }
        let panicURL = try requiredOption("--panic-url", in: arguments)
        let mediaURL = try requiredOption("--media-url", in: arguments)
        let auditHead = optionValue("--audit-head", in: arguments) ?? "unbound"
        let json = arguments.contains("--json")

        let panic = try runPanicProof(baseURL: trimSlash(panicURL), auditHead: auditHead)
        let media = try runMediaProof(baseURL: trimSlash(mediaURL), auditHead: auditHead)
        let pass = (panic["status"] as? String) == "pass" && (media["status"] as? String) == "pass"
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "surface": "OpenBurnBarCLI computer-use live-surface-proof",
            "status": pass ? "pass" : "fail",
            "panic": panic,
            "media": media
        ]
        let output = try jsonString(payload, pretty: json)
        return BurnBarCLIInvocationResult(output: output, exitCode: pass ? 0 : 1)
    }

    private static func runPanicProof(baseURL: String, auditHead: String) throws -> [String: Any] {
        let session = try requestJSON(
            url: "\(baseURL)/session/start",
            body: [
                "sessionId": "linux-panic-sim-\(UUID().uuidString)",
                "resources": ["capture", "input", "media"],
                "auditHeadHash": auditHead
            ]
        )
        let paths = [
            ("app-ui", "app_ui_button"),
            ("daemon-cli-rpc", "daemon_rpc"),
            ("mobile-remote", "mobile_remote"),
            ("global-system", "global_system_equivalent")
        ]
        var rows: [[String: Any]] = []
        var allPassed = (session["resourcesActive"] as? Bool) == true
        for (path, source) in paths {
            let response = try requestJSON(
                url: "\(baseURL)/panic",
                body: [
                    "path": path,
                    "source": source,
                    "budgetMs": 500,
                    "auditHeadHash": auditHead
                ]
            )
            let duration = response["durationMs"] as? Int ?? Int.max
            let passed = (response["halted"] as? Bool) == true
                && (response["captureClosed"] as? Bool) == true
                && (response["inputClosed"] as? Bool) == true
                && (response["mediaClosed"] as? Bool) == true
                && (response["auditEntryRecorded"] as? Bool) == true
                && duration <= 500
            allPassed = allPassed && passed
            rows.append([
                "path": path,
                "source": source,
                "status": passed ? "pass" : "fail",
                "durationMs": duration,
                "budgetMs": 500,
                "response": response
            ])
        }
        let restart = try requestJSON(
            url: "\(baseURL)/daemon/restart",
            body: [
                "auditHeadHash": auditHead,
                "expectReconnect": true
            ]
        )
        let restartPassed = (restart["haltStateSurvivedRestart"] as? Bool) == true
            && (restart["reconnected"] as? Bool) == true
        allPassed = allPassed && restartPassed
        return [
            "target": "VAL-CU-003",
            "status": allPassed ? "pass" : "fail",
            "session": session,
            "rows": rows,
            "restartReconnect": restart
        ]
    }

    private static func runMediaProof(baseURL: String, auditHead: String) throws -> [String: Any] {
        let negotiation = try requestJSON(
            url: "\(baseURL)/media/negotiate",
            body: [
                "protocol": "openburnbar/mercury/simulator-interop/1",
                "localCodecs": ["h264", "opus", "media-frame-v2"],
                "auditHeadHash": auditHead
            ]
        )
        let screen = try requestJSON(
            url: "\(baseURL)/media/frame",
            body: [
                "flow": "screen-share-viewer",
                "encrypted": true,
                "controlMetadata": [
                    "cursor": "present",
                    "streamClass": "media.screen.video",
                    "wireVersion": "media-frame-v2"
                ]
            ]
        )
        let file = try requestJSON(
            url: "\(baseURL)/media/file",
            body: [
                "flow": "file-transfer",
                "encrypted": true,
                "bytes": 4096
            ]
        )
        let call = try requestJSON(
            url: "\(baseURL)/media/call",
            body: [
                "flow": "one-to-one-call",
                "audioCodec": "opus",
                "control": "viewer-start-stop"
            ]
        )
        let passed = (negotiation["accepted"] as? Bool) == true
            && (screen["nonLoopback"] as? Bool) == true
            && (screen["encryptedFrameMetadata"] as? Bool) == true
            && (screen["wireDiffAdditive"] as? Bool) == true
            && (file["encrypted"] as? Bool) == true
            && (call["audioCodec"] as? String) == "opus"
        return [
            "target": "VAL-MEDIA-001",
            "status": passed ? "pass" : "fail",
            "negotiation": negotiation,
            "screenShare": screen,
            "fileTransfer": file,
            "call": call
        ]
    }

    private static func requestJSON(url: String, body: [String: Any]) throws -> [String: Any] {
        guard let curl = which("curl") else {
            throw BurnBarCLIError.invalidCommand("computer-use live-surface-proof requires curl")
        }
        let requestBody = try jsonData(body)
        let result = runCommand(
            path: curl,
            arguments: [
                "-fsS",
                "--max-time",
                "3",
                "-X",
                "POST",
                "-H",
                "Content-Type: application/json",
                "--data",
                String(data: requestBody, encoding: .utf8) ?? "{}",
                url
            ]
        )
        guard result.exitCode == 0 else {
            throw BurnBarCLIError.invalidCommand(
                "computer-use live-surface-proof request failed: \(url) exit=\(result.exitCode) \(result.stderr)"
            )
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BurnBarCLIError.invalidCommand("computer-use live-surface-proof returned non-JSON from \(url)")
        }
        var withTrace = json
        withTrace["_requestURL"] = url
        return withTrace
    }

    private struct CommandResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private static func runCommand(path: String, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: 127, stdout: "", stderr: error.localizedDescription)
        }
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: readPipe(output),
            stderr: readPipe(error)
        )
    }

    private static func requiredOption(_ name: String, in arguments: [String]) throws -> String {
        guard let value = optionValue(name, in: arguments), value.isEmpty == false else {
            throw BurnBarCLIError.missingArgument("\(name) is required. \(usageText)")
        }
        return value
    }

    private static func optionValue(_ name: String, in arguments: [String]) -> String? {
        for (index, value) in arguments.enumerated() where value == name {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { return nil }
            return arguments[next]
        }
        return nil
    }

    private static func trimSlash(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func which(_ name: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in pathValue.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func jsonString(_ value: [String: Any], pretty: Bool) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        )
        guard let output = String(data: data, encoding: .utf8) else {
            throw BurnBarCLIError.missingArgument("Could not encode computer-use proof JSON.")
        }
        return output
    }

    private static func jsonData(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
