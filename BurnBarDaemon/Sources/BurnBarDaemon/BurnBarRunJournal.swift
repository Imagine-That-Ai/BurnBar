import BurnBarCore
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

        let encodedEvent = try encoder.encode(event) + Data([0x0A])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encodedEvent)
        } else {
            try encodedEvent.write(to: fileURL, options: .atomic)
        }

        if cachedEvents != nil {
            cachedEvents?.append(event)
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
