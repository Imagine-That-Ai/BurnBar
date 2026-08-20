import Foundation

/// Main-app handler for files dropped into the share inbox. The Share Extension
/// appex itself is a named CHANGELOG blocker; this processes App Group / inbox
/// copies when the host app becomes active.
enum BurnbarShareInboxProcessor {
    static func inboxDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("share-inbox", isDirectory: true)
    }

    static func pendingFiles() -> [URL] {
        let root = inboxDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return items.filter { $0.pathExtension != "pending" && $0.pathExtension != "uploading" }
    }

    @MainActor
    static func processPending(deviceId: String) async {
        for fileURL in pendingFiles() {
            _ = try? await BurnbarAttachmentUploadClient.uploadFile(fileURL: fileURL, deviceId: deviceId)
        }
    }
}
