#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

enum MercuryLinuxFileTransferFactory {
    private static let mercuryDirectoryName = "Mercury"
    private static let blobStoreDirectoryName = "BlobStore"
    private static let inboxDirectoryName = "InboxStaging"
    private static let secretFileName = "blob-secret.bin"

    static func make(logger: BurnBarDaemonLogger) -> MediaFileTransferService? {
        guard let backend = OpenBurnBarIrohBlobFFIBackendFactory.make() else {
            logger.info("linux_media_file_transfer_unavailable", metadata: ["reason": "iroh_blob_ffi_missing"])
            return nil
        }

        let mercuryDirectory = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent(mercuryDirectoryName, isDirectory: true)
        let storeDirectory = mercuryDirectory.appendingPathComponent(blobStoreDirectoryName, isDirectory: true)
        let inboxDirectory = mercuryDirectory.appendingPathComponent(inboxDirectoryName, isDirectory: true)
        let secretURL = mercuryDirectory.appendingPathComponent(secretFileName, isDirectory: false)

        return MediaFileTransferService(
            backend: backend,
            configuration: MediaFileTransferService.Configuration(
                storeDirectoryURL: storeDirectory,
                inboxDirectoryURL: inboxDirectory,
                secretKeyProvider: {
                    try secretKeyMaterial(at: secretURL)
                },
                relayURL: nil
            )
        )
    }

    static func downloadDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = trimmedNonEmpty(environment["XDG_DOWNLOAD_DIR"]) {
            return expandedUserPath(configured, environment: environment, isDirectory: true)
        }
        if let home = trimmedNonEmpty(environment["HOME"]) {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    static func secretKeyMaterial(at url: URL) throws -> Data {
        if let existing = try? Data(contentsOf: url), existing.count == 32 {
            return existing
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fresh = try PlatformCrypto.secureRandomBytes(count: 32)
        try fresh.write(to: url, options: [.atomic])
        _ = chmod(url.path, mode_t(S_IRUSR | S_IWUSR))
        return fresh
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private static func expandedUserPath(
        _ path: String,
        environment: [String: String],
        isDirectory: Bool
    ) -> URL {
        let home = trimmedNonEmpty(environment["HOME"]) ?? FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return URL(fileURLWithPath: home, isDirectory: isDirectory)
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: isDirectory)
        }
        if path.hasPrefix("$HOME/") {
            let suffix = String(path.dropFirst("$HOME/".count))
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: isDirectory)
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }
}
#endif
