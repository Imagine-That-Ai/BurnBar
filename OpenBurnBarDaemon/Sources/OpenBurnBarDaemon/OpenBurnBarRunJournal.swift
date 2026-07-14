import OpenBurnBarEngine
import Foundation

public actor BurnBarRunJournal {
    private let fileURL: URL
    private let checkpointsDirectoryURL: URL
    private let logger: BurnBarDaemonLogger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cachedEvents: [BurnBarRunJournalEvent]?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultRunJournalURL,
        checkpointsDirectoryURL: URL = BurnBarDaemonPaths.defaultRunCheckpointDirectoryURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "run-journal")
    ) {
        self.fileURL = fileURL
        self.checkpointsDirectoryURL = checkpointsDirectoryURL
        self.logger = logger
    }

    public func append(_ event: BurnBarRunJournalEvent) throws {
        try ensureParentDirectory(for: fileURL)

        let persistedEvent = try BurnBarRunJournalPrivacyRedactor.redacted(event)
        let encodedEvent = try encoder.encode(persistedEvent) + Data([0x0A])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encodedEvent)
        } else {
            try encodedEvent.write(to: fileURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        if cachedEvents != nil {
            cachedEvents?.append(persistedEvent)
        }

        logger.debug(
            "run_journal_event_appended",
            metadata: [
                "run_id": event.runID.rawValue,
                "kind": event.kind.rawValue
            ]
        )
    }

    public func events(for runID: BurnBarRunID? = nil) throws -> [BurnBarRunJournalEvent] {
        let events = try loadEventsIfNeeded()
        guard let runID else {
            return events
        }
        return events.filter { $0.runID == runID }
    }

    public func writeCheckpoint(_ checkpoint: BurnBarRunJournalCheckpoint) throws {
        try FileManager.default.createDirectory(
            at: checkpointsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let checkpointURL = checkpointFileURL(for: checkpoint.runID)
        let data = try encoder.encode(checkpoint)
        try data.write(to: checkpointURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)

        logger.debug(
            "run_journal_checkpoint_written",
            metadata: [
                "run_id": checkpoint.runID.rawValue,
                "phase": checkpoint.phase.rawValue
            ]
        )
    }

    public func checkpoint(for runID: BurnBarRunID) throws -> BurnBarRunJournalCheckpoint? {
        let checkpointURL = checkpointFileURL(for: runID)
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: checkpointURL)
        return try decoder.decode(BurnBarRunJournalCheckpoint.self, from: data)
    }

    public func allCheckpoints() throws -> [BurnBarRunJournalCheckpoint] {
        guard FileManager.default.fileExists(atPath: checkpointsDirectoryURL.path) else {
            return []
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: checkpointsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        return fileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                do {
                    let data = try Data(contentsOf: url)
                    return try decoder.decode(BurnBarRunJournalCheckpoint.self, from: data)
                } catch {
                    logger.error(
                        "run_journal_checkpoint_skipped",
                        metadata: [
                            "checkpoint_path": url.path,
                            "error": error.localizedDescription
                        ]
                    )
                    return nil
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadEventsIfNeeded() throws -> [BurnBarRunJournalEvent] {
        if let cachedEvents {
            return cachedEvents
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedEvents = []
            return []
        }

        let fileContents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = fileContents.split(whereSeparator: \.isNewline)
        let events = lines.compactMap { line -> BurnBarRunJournalEvent? in
            do {
                return try decoder.decode(BurnBarRunJournalEvent.self, from: Data(line.utf8))
            } catch {
                logger.error(
                    "run_journal_event_skipped",
                    metadata: [
                        "error": error.localizedDescription
                    ]
                )
                return nil
            }
        }
        cachedEvents = events
        return events
    }

    private func checkpointFileURL(for runID: BurnBarRunID) -> URL {
        checkpointsDirectoryURL.appendingPathComponent("\(runID.rawValue).json", isDirectory: false)
    }

    private func ensureParentDirectory(for fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

private enum BurnBarRunJournalPrivacyRedactor {
    private static let redactedMarker = "[REDACTED]"

    private static let sensitiveExactKeyNames: Set<String> = [
        "apikey",
        "accesstoken",
        "authorization",
        "authtoken",
        "bearer",
        "bearertoken",
        "bottoken",
        "clientsecret",
        "cookie",
        "credential",
        "credentialplaintext",
        "credentialsecret",
        "idtoken",
        "password",
        "passwd",
        "privatekey",
        "refreshtoken",
        "secret",
        "sessiontoken",
        "token"
    ]

    private static let nonSecretTokenMetricKeyNames: Set<String> = [
        "cachecreationtokens",
        "cachereadtokens",
        "completiontokens",
        "inputtokens",
        "outputtokens",
        "prompttokens",
        "reasoningtokens",
        "tokencount",
        "tokencounts",
        "tokenusage",
        "totaltokens"
    ]

    private static let redactionExpressions: [(regex: NSRegularExpression, label: String)] = [
        (#"(?i)["']?\b(authorization|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|bot[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|cookie)\b["']?\s*[:=]\s*("[^"]*"|'[^']*'|[^,\s}\]]+)"#, redactedMarker),
        (#"(?i)\bbearer\s+[A-Za-z0-9._\-]{8,}"#, redactedMarker),
        (#"\b\d{6,}:[A-Za-z0-9_\-]{16,}\b"#, redactedMarker)
    ].compactMap { pattern, label in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, label) }
    }

    static func redacted(_ event: BurnBarRunJournalEvent) throws -> BurnBarRunJournalEvent {
        BurnBarRunJournalEvent(
            eventID: event.eventID,
            runID: event.runID,
            kind: event.kind,
            phase: event.phase,
            payload: event.payload.map { sanitize($0) },
            emittedAt: event.emittedAt
        )
    }

    private static func sanitize(_ value: BurnBarJSONValue, key: String? = nil) -> BurnBarJSONValue {
        if let key, isSensitiveKey(key) {
            switch value {
            case .bool, .null:
                return value
            default:
                return .string(redactedMarker)
            }
        }

        switch value {
        case .string(let string):
            return .string(redactText(string))
        case .object(let object):
            return .object(sanitizeObject(object))
        case .array(let array):
            return .array(array.map { sanitize($0) })
        case .number, .bool, .null:
            return value
        }
    }

    private static func sanitizeObject(_ object: [String: BurnBarJSONValue]) -> [String: BurnBarJSONValue] {
        object.reduce(into: [:]) { sanitized, entry in
            sanitized[entry.key] = sanitize(entry.value, key: entry.key)
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if nonSecretTokenMetricKeyNames.contains(normalized) {
            return false
        }
        if sensitiveExactKeyNames.contains(normalized) {
            return true
        }
        if normalized.contains("apikey")
            || normalized.contains("authorization")
            || normalized.contains("credential")
            || normalized.contains("password")
            || normalized.contains("privatekey")
            || normalized.contains("secret")
            || normalized.contains("token") {
            return true
        }
        return false
    }

    private static func redactText(_ value: String) -> String {
        var result = value
        result = ProviderRoutingPolicy.sanitizedAuditText(result)
        for expression in redactionExpressions {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: expression.label
            )
        }
        return result
    }
}
