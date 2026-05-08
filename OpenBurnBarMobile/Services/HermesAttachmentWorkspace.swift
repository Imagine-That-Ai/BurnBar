import Foundation
import OpenBurnBarCore

// MARK: - Hermes Attachment Workspace (iOS / iPadOS)

/// File-system glue for storing Hermes chat attachments on iPhone / iPad.
/// Lives under `Documents/HermesChats/<threadID>/attachments/` so the user
/// can browse the bytes via the Files app if they want, and so iCloud
/// document backups carry attachments along with the rest of the app's data.
enum HermesAttachmentWorkspace {
    /// Default thread folder name used while we don't yet have multi-thread
    /// chats on mobile. Stable across launches so subsequent sends stay in
    /// the same workspace.
    static let defaultThreadID = "default"

    /// Documents/HermesChats/<threadID>/ — created lazily.
    static func threadRoot(threadID: String = defaultThreadID) -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let chats = docs.appendingPathComponent("HermesChats", isDirectory: true)
        let thread = chats.appendingPathComponent(threadID, isDirectory: true)
        return thread
    }

    /// Documents/HermesChats/<threadID>/attachments/ — created on demand.
    static func attachmentsRoot(threadID: String = defaultThreadID) -> URL? {
        guard let root = threadRoot(threadID: threadID) else { return nil }
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return root // workspace root, attachments live under attachments/
    }

    /// Same as `attachmentsRoot` but doesn't materialise the directory if it
    /// doesn't exist — used by the encoder's reference-fallback path.
    static var attachmentsRootIfReady: URL? {
        guard let root = threadRoot() else { return nil }
        return root
    }

    /// Loads bytes for a stored attachment, used by the request-body encoder.
    static func loadBytes(for attachment: HermesAttachment, in workspaceRoot: URL) -> Data? {
        let url = workspaceRoot.appendingPathComponent(attachment.workspaceRelativePath)
        return try? Data(contentsOf: url)
    }

    /// Absolute path string for diagnostic / workspace-reference output.
    static func absolutePath(for attachment: HermesAttachment, in workspaceRoot: URL) -> String {
        workspaceRoot.appendingPathComponent(attachment.workspaceRelativePath).path
    }
}
