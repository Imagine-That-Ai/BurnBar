import Foundation

/// Result of one read-only transcript poll. Never a write error.
enum GrokDTranscriptRead: Equatable, Sendable {
    case completed
    case promptLanded
    case noEvidence
    case skippedBusy
    case unavailable
}

protocol GrokDTranscriptReading: Sendable {
    func read(path: String, token: String) async -> GrokDTranscriptRead
}

/// Opens `store.db` via `/usr/bin/sqlite3 -readonly`. SELECT only.
/// SQLITE_BUSY skips the poll. Never INSERT / UPDATE / DELETE.
struct GrokDReadonlyTranscriptReader: GrokDTranscriptReading, Sendable {
    var busyTimeoutMilliseconds: Int32
    var limit: Int
    var sqlite3URL: URL

    init(
        busyTimeoutMilliseconds: Int32 = 5000,
        limit: Int = 40,
        sqlite3URL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    ) {
        self.busyTimeoutMilliseconds = max(0, busyTimeoutMilliseconds)
        self.limit = min(max(1, limit), 100)
        self.sqlite3URL = sqlite3URL
    }

    func read(path: String, token: String) async -> GrokDTranscriptRead {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, Self.isStorePath(path) else { return .unavailable }
        let timeout = busyTimeoutMilliseconds
        let rowLimit = limit
        let tool = sqlite3URL
        return await Task.detached(priority: .utility) {
            Self.runReadonlySelect(
                sqlite3URL: tool,
                path: path,
                busyTimeoutMilliseconds: timeout,
                limit: rowLimit,
                token: needle
            )
        }.value
    }

    static func isStorePath(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized.hasSuffix("/store.db") else { return false }
        return !standardized.contains("\0")
    }

    /// `entriesNewestFirst` matches `ORDER BY rowid DESC`. Success is a user
    /// line that carries the token and a later assistant / send-message line.
    static func interpret(entriesNewestFirst: [String], token: String) -> GrokDTranscriptRead {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .noEvidence }
        var sawUser = false
        for raw in entriesNewestFirst.reversed() {
            let line = classify(raw, token: needle)
            if !sawUser {
                if line == .user { sawUser = true }
                continue
            }
            if line == .assistant { return .completed }
        }
        return sawUser ? .promptLanded : .noEvidence
    }

    private static func runReadonlySelect(
        sqlite3URL: URL,
        path: String,
        busyTimeoutMilliseconds: Int32,
        limit: Int,
        token: String
    ) -> GrokDTranscriptRead {
        let process = Process()
        process.executableURL = sqlite3URL
        process.arguments = [
            "-batch",
            "-readonly",
            "-noheader",
            path,
            "PRAGMA busy_timeout=\(busyTimeoutMilliseconds); SELECT entry FROM transcript_entries ORDER BY rowid DESC LIMIT \(limit);"
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .unavailable
        }
        process.waitUntilExit()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            if isBusyMessage(err) || process.terminationStatus == 5 {
                return .skippedBusy
            }
            return .unavailable
        }
        if isBusyMessage(err) {
            return .skippedBusy
        }
        let out = String(data: outData, encoding: .utf8) ?? ""
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
        let hay = fields.content.isEmpty ? raw : fields.content
        guard hay.contains(token) || raw.contains(token) else { return .other }
        return .user
    }

    private static func parse(_ raw: String) -> (role: String?, kind: String?, content: String) {
        guard let data = raw.data(using: .utf8) else {
            return (nil, nil, raw)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return (nil, nil, raw)
        }
        guard let obj = object as? [String: Any] else {
            return (nil, nil, raw)
        }
        let role = obj["role"] as? String
        let kind = obj["kind"] as? String
        var content = ""
        if let value = obj["content"] as? String { content += value }
        if let value = obj["prompt"] as? String { content += value }
        if let message = obj["message"] as? [String: Any], let value = message["content"] as? String {
            content += value
        }
        return (role, kind, content)
    }
}
