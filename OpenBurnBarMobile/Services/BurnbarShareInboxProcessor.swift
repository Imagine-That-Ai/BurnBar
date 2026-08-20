import Foundation

/// Main-app handler for files dropped into the share inbox. The Share Extension
/// appex itself is a named CHANGELOG blocker; this processes App Group / inbox
/// copies when the host app becomes active.
enum BurnbarShareInboxProcessor {
    static func inboxDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("share-inbox", isDirectory: true)
    }

    static func pendingFiles(in root: URL? = nil) -> [URL] {
        let root = root ?? inboxDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return items.filter {
            let ext = $0.pathExtension
            return ext != "pending" && ext != "uploading" && ext != "failed" && ext != "done"
        }
    }

    /// After success or a permanent failure the inbox item is consumed so
    /// `didBecomeActive` cannot begin the same file twice.
    @MainActor
    static func processPending(
        deviceId: String,
        inbox: URL? = nil,
        upload: (URL, String) async throws -> Void = { fileURL, deviceId in
            _ = try await BurnbarAttachmentUploadClient.uploadFile(fileURL: fileURL, deviceId: deviceId)
        }
    ) async {
        let root = inbox ?? inboxDirectory()
        for fileURL in pendingFiles(in: root) {
            do {
                try await upload(fileURL, deviceId)
                consume(fileURL)
            } catch {
                if isPermanentFailure(error) {
                    consume(fileURL)
                }
            }
        }
    }

    static func isPermanentFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("missing") || text.contains("not found") || text.contains("invalid")
    }

    static func consume(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
