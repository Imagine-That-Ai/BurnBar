import OpenBurnBarCore
import Foundation

struct MissionControlJournalRepository {
    let eventsFileURL: URL
    let projectionFileURL: URL
    let logger: BurnBarDaemonLogger

    static func ensureParentDirectory(for fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func readEventsFromDisk(decoder: JSONDecoder) throws -> [BurnBarControllerEvent] {
        guard FileManager.default.fileExists(atPath: eventsFileURL.path) else {
            return []
        }

        let content = try String(contentsOf: eventsFileURL, encoding: .utf8)
        return content
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> BurnBarControllerEvent? in
                guard line.isEmpty == false else { return nil }
                if Task.isCancelled { return nil }
                do {
                    return try decoder.decode(BurnBarControllerEvent.self, from: Data(line.utf8))
                } catch {
                    logger.error(
                        "controller_event_skipped",
                        metadata: ["error": error.localizedDescription]
                    )
                    return nil
                }
            }
    }

    func readRecentEventsFromDisk(limit: Int, decoder: JSONDecoder) throws -> [BurnBarControllerEvent] {
        guard limit > 0,
              FileManager.default.fileExists(atPath: eventsFileURL.path) else {
            return []
        }

        let handle = try FileHandle(forReadingFrom: eventsFileURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else { return [] }

        let chunkSize: UInt64 = 64 * 1024
        let maxTailBytes: UInt64 = 4 * 1024 * 1024
        var offset = fileSize
        var tail = Data()
        var newlineCount = 0

        while offset > 0 && newlineCount <= limit && UInt64(tail.count) < maxTailBytes {
            try Task.checkCancellation()
            let readSize = min(chunkSize, offset)
            offset -= readSize
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: Int(readSize)), chunk.isEmpty == false else {
                break
            }
            tail.insert(contentsOf: chunk, at: 0)
            newlineCount = tail.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
        }

        return String(decoding: tail, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .suffix(limit)
            .compactMap { line -> BurnBarControllerEvent? in
                guard line.isEmpty == false else { return nil }
                do {
                    return try decoder.decode(BurnBarControllerEvent.self, from: Data(line.utf8))
                } catch {
                    logger.error(
                        "controller_recent_event_skipped",
                        metadata: ["error": error.localizedDescription]
                    )
                    return nil
                }
            }
    }

    func appendEventToDisk(_ event: BurnBarControllerEvent, encoder: JSONEncoder) throws {
        try Self.ensureParentDirectory(for: eventsFileURL)
        let data = try encoder.encode(event) + Data([0x0A])
        if FileManager.default.fileExists(atPath: eventsFileURL.path) {
            let handle = try FileHandle(forWritingTo: eventsFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: eventsFileURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eventsFileURL.path)
    }

    func writeProjectionFile(_ projection: BurnBarMissionControlProjectionFile, encoder: JSONEncoder) throws {
        try Self.ensureParentDirectory(for: projectionFileURL)
        let data = try encoder.encode(projection)
        try data.write(to: projectionFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: projectionFileURL.path)
    }

    func loadProjectionFromDiskIfPresent(decoder: JSONDecoder) throws -> BurnBarMissionControlProjectionFile? {
        guard FileManager.default.fileExists(atPath: projectionFileURL.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: projectionFileURL)
        } catch {
            logger.silentFailure("load_projection_data", error: error)
            return nil
        }
        do {
            return try decoder.decode(BurnBarMissionControlProjectionFile.self, from: data)
        } catch {
            logger.silentFailure("decode_projection", error: error)
            return nil
        }
    }
}
