import CryptoKit
import Foundation

/// Recursive, content-aware manifest used by hermetic refresh tests. It
/// intentionally records metadata and a SHA-256 for every regular file so a
/// nested or same-size/content-only write is observable.
struct RecursiveFileManifestEntry: Equatable, Sendable {
    let type: String
    let size: UInt64
    let creationTime: TimeInterval?
    let modificationTime: TimeInterval?
    let contentHash: String?
}

enum RecursiveSupportManifest {
    static func make(for root: URL, fileManager: FileManager = .default) -> [String: RecursiveFileManifestEntry] {
        let standardizedRoot = root.standardizedFileURL
        var urls = [standardizedRoot]
        if let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            urls.append(contentsOf: enumerator.compactMap { $0 as? URL })
        }

        var manifest: [String: RecursiveFileManifestEntry] = [:]
        for url in urls.sorted(by: { $0.path < $1.path }) {
            let relativePath = relativePath(for: url, root: standardizedRoot)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                manifest[relativePath] = RecursiveFileManifestEntry(
                    type: "unreadable",
                    size: 0,
                    creationTime: nil,
                    modificationTime: nil,
                    contentHash: nil
                )
                continue
            }

            let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "unknown"
            manifest[relativePath] = RecursiveFileManifestEntry(
                type: type,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                creationTime: timestamp(attributes[.creationDate]),
                modificationTime: timestamp(attributes[.modificationDate]),
                contentHash: type == FileAttributeType.typeRegular.rawValue
                    ? sha256(for: url)
                    : nil
            )
        }
        return manifest
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path != root.path else { return "." }
        return String(path.dropFirst(root.path.count + 1))
    }

    private static func timestamp(_ value: Any?) -> TimeInterval? {
        (value as? Date)?.timeIntervalSince1970
    }

    private static func sha256(for url: URL) -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                guard let chunk = try handle.read(upToCount: 1024 * 1024),
                      !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }
}
