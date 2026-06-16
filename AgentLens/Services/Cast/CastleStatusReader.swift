import Foundation
import OpenBurnBarCore

struct CastleStatusLoadFailure: Equatable, Identifiable {
    let path: String
    let reason: String

    var id: String { path }
}

struct CastleStatusLoadResult: Equatable {
    static let empty = CastleStatusLoadResult(snapshot: CastleRunSnapshot(workers: []), failures: [], loadedAt: nil)

    let snapshot: CastleRunSnapshot
    let failures: [CastleStatusLoadFailure]
    let loadedAt: Date?
}

enum CastleStatusReader {
    static let defaultStatusRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenBurnBar", isDirectory: true)
            .appendingPathComponent("castle", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }()

    static func decodeRecord(data: Data) throws -> CastleWorkerStatus {
        try JSONDecoder().decode(CastleWorkerStatus.self, from: data)
    }

    static func loadStatusRecords(at urls: [URL]) -> CastleStatusLoadResult {
        var records: [CastleWorkerStatus] = []
        var failures: [CastleStatusLoadFailure] = []

        for url in urls {
            do {
                records.append(try decodeRecord(data: try Data(contentsOf: url)))
            } catch {
                failures.append(CastleStatusLoadFailure(path: url.path, reason: String(describing: error)))
            }
        }

        return CastleStatusLoadResult(
            snapshot: CastleRunSnapshot(workers: records),
            failures: failures,
            loadedAt: Date()
        )
    }

    static func recentStatusURLs(
        root: URL = defaultStatusRoot,
        limit: Int = 24,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent == "status.json" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(max(0, limit))
            .map { $0.url.resolvingSymlinksInPath().standardizedFileURL }
    }

    static func configuredStatusURLs(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var paths: [String] = []
        if let raw = environment["OPENBURNBAR_CASTLE_STATUS_PATHS"] {
            paths.append(contentsOf: splitPathList(raw))
        }
        if let raw = UserDefaults.standard.array(forKey: "castleStatusPaths") as? [String] {
            paths.append(contentsOf: raw)
        }
        return Array(Set(paths))
            .sorted()
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    private static func splitPathList(_ raw: String) -> [String] {
        raw.split { character in
            character == "\n" || character == "," || character == ";" || character == ":"
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
}
