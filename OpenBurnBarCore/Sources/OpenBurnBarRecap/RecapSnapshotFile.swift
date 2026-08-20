import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// The JSON-on-disk bootstrap shared by the recap's two persisted snapshots.
///
/// `RecapStore` and `RecapHistoryStore` hold different payloads and enforce
/// different staleness rules, but they load and write identically: ISO-8601
/// dates, sorted keys so a diff of the file stays readable, and a tolerant read
/// that falls back to an empty snapshot instead of throwing. Written once here
/// because two copies of a persistence bootstrap drift into two file formats.
enum RecapSnapshotFile {

    static func makeEncoder() -> JSONEncoder {
        let coder = JSONEncoder()
        coder.dateEncodingStrategy = .iso8601
        coder.outputFormatting = [.sortedKeys]
        return coder
    }

    static func makeDecoder() -> JSONDecoder {
        let coder = JSONDecoder()
        coder.dateDecodingStrategy = .iso8601
        return coder
    }

    /// Decode `fileURL`, or create its enclosing directory and take `fallback`.
    ///
    /// Missing, empty, and undecodable files all take the fallback on purpose: a
    /// recap that rebuilds itself is a far better failure than one that refuses
    /// to open because last month's file was written by an older shape.
    static func load<Snapshot: Decodable>(
        _ type: Snapshot.Type,
        from fileURL: URL,
        decoder: JSONDecoder,
        fallback: () -> Snapshot
    ) throws -> Snapshot {
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           !data.isEmpty,
           let decoded = try? decoder.decode(type, from: data) {
            return decoded
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return fallback()
    }
}
