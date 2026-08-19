import Darwin
import Foundation
import os

enum GrokDTranscriptRead: Equatable, Sendable {
    case completed
    case promptLanded
    case noEvidence
    case skippedBusy
    case unavailable
}

protocol GrokDTranscriptReading: Sendable {
    func read(path: String, agentID: String, token: String) async -> GrokDTranscriptRead
}

/// CLI sqlite3 so the SQLCipher dylib never opens plaintext `store.db`.
struct GrokDReadonlyTranscriptReader: GrokDTranscriptReading, Sendable {
    var busyTimeoutMilliseconds: Int32
    var limit: Int
    var sqlite3URL: URL
    var waitNanoseconds: UInt64

    init(
        busyTimeoutMilliseconds: Int32 = 80,
        limit: Int = 40,
        sqlite3URL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        waitNanoseconds: UInt64 = 800_000_000
    ) {
        self.busyTimeoutMilliseconds = max(0, busyTimeoutMilliseconds)
        self.limit = min(max(1, limit), 100)
        self.sqlite3URL = sqlite3URL
        self.waitNanoseconds = waitNanoseconds
    }

    func read(path: String, agentID: String, token: String) async -> GrokDTranscriptRead {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let canonical = Self.canonicalStorePath(path: path, agentID: agentID) else {
            return .unavailable
        }
        let timeout = busyTimeoutMilliseconds
        let rowLimit = limit
        let tool = sqlite3URL
        let waitNs = waitNanoseconds
        let pidBox = OSAllocatedUnfairLock(initialState: Int32(0))
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                Self.runReadonlySelect(
                    sqlite3URL: tool,
                    path: canonical,
                    busyTimeoutMilliseconds: timeout,
                    limit: rowLimit,
                    token: needle,
                    waitNanoseconds: waitNs,
                    pidBox: pidBox
                )
            }.value
        } onCancel: {
            let pid = pidBox.withLock { $0 }
            if pid > 0 {
                _ = Darwin.kill(pid, SIGTERM)
            }
        }
    }

    static func canonicalStorePath(path: String, agentID: String) -> String? {
        guard GrokDHostClient.isAgentUUID(agentID) else { return nil }
        guard !path.contains("\0"), !path.hasPrefix("~") else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let expectedSuffix = "/box-data/agents/\(agentID)/store.db"
        guard resolved.hasPrefix("/"), resolved.hasSuffix(expectedSuffix) else { return nil }
        guard !resolved.contains("/../") else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) {
            if isDir.boolValue { return nil }
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: resolved)
            } catch {
                return nil
            }
            if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
                return nil
            }
        }
        return resolved
    }

    /// Newest matching user row, then a strictly newer assistant / send-message.
    static func interpret(entriesNewestFirst: [String], token: String) -> GrokDTranscriptRead {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .noEvidence }
        var sawNewerAssistant = false
        for raw in entriesNewestFirst {
            let line = classify(raw, token: needle)
            if line == .assistant {
                sawNewerAssistant = true
                continue
            }
            if line == .user {
                return sawNewerAssistant ? .completed : .promptLanded
            }
        }
        return .noEvidence
    }

    private static func runReadonlySelect(
        sqlite3URL: URL,
        path: String,
        busyTimeoutMilliseconds: Int32,
        limit: Int,
        token: String,
        waitNanoseconds: UInt64,
        pidBox: OSAllocatedUnfairLock<Int32>
    ) -> GrokDTranscriptRead {
        let process = Process()
        process.executableURL = sqlite3URL
        process.arguments = [
            "-batch",
            "-readonly",
            "-noheader",
            "-cmd",
            "PRAGMA busy_timeout=\(busyTimeoutMilliseconds)",
            path,
            "SELECT entry FROM transcript_entries ORDER BY rowid DESC LIMIT \(limit);"
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let outBox = OSAllocatedUnfairLock(initialState: Data())
        let errBox = OSAllocatedUnfairLock(initialState: Data())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                outBox.withLock { $0.append(chunk) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                errBox.withLock { $0.append(chunk) }
            }
        }
        do {
            try process.run()
        } catch {
            return .unavailable
        }
        pidBox.withLock { $0 = process.processIdentifier }
        let started = DispatchTime.now()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                break
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
            if elapsed > waitNanoseconds {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        pidBox.withLock { $0 = 0 }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        outBox.withLock { $0.append(stdout.fileHandleForReading.availableData) }
        errBox.withLock { $0.append(stderr.fileHandleForReading.availableData) }
        let err = String(data: errBox.withLock { $0 }, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            if isBusyMessage(err) || process.terminationStatus == 5 {
                return .skippedBusy
            }
            return .unavailable
        }
        if isBusyMessage(err) {
            return .skippedBusy
        }
        let out = String(data: outBox.withLock { $0 }, encoding: .utf8) ?? ""
        let entries = out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        return interpret(entriesNewestFirst: entries, token: token)
    }

    private static func isBusyMessage(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("database is locked") || lower.contains("database is busy")
    }

    private enum LineKind {
        case user
        case assistant
        case other
    }

    private static func classify(_ raw: String, token: String) -> LineKind {
        let fields = parse(raw)
        if fields.kind == "send-message" || fields.role == "assistant" {
            return .assistant
        }
        let hay = fields.parsed ? fields.content : raw
        guard contentMatchesPrompt(hay, token: token) else { return .other }
        if !fields.parsed {
            return .user
        }
        if fields.role == "user" || fields.kind == "message" || fields.type == "prompt" {
            return .user
        }
        return .other
    }

    private static func contentMatchesPrompt(_ content: String, token: String) -> Bool {
        if content == token { return true }
        return !content.isEmpty && token.hasPrefix(content)
    }

    private struct EntryFields {
        var role: String?
        var kind: String?
        var type: String?
        var content: String
        var parsed: Bool
    }

    private static func parse(_ raw: String) -> EntryFields {
        guard let data = raw.data(using: .utf8) else {
            return EntryFields(role: nil, kind: nil, type: nil, content: raw, parsed: false)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return EntryFields(role: nil, kind: nil, type: nil, content: raw, parsed: false)
        }
        guard let obj = object as? [String: Any] else {
            return EntryFields(role: nil, kind: nil, type: nil, content: raw, parsed: false)
        }
        var content = ""
        if let value = obj["content"] as? String { content += value }
        if let value = obj["prompt"] as? String { content += value }
        if let message = obj["message"] as? [String: Any], let value = message["content"] as? String {
            content += value
        }
        return EntryFields(
            role: obj["role"] as? String,
            kind: obj["kind"] as? String,
            type: obj["type"] as? String,
            content: content,
            parsed: true
        )
    }
}
