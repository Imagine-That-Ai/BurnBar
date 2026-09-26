import Foundation
import AppKit
import OpenBurnBarAssistantModels
import OpenBurnBarKernel
import UniformTypeIdentifiers

/// Loads files from disk / `NSImage` into the chat workspace and produces
/// `HermesAttachment` metadata. Mirrors the iOS loader of the same name so
/// the macOS / iOS / iPadOS surfaces produce identical attachments.
///
/// Wave 3.4 macOS back: every entry point is AppKit-bound so the loader
/// stays in-app; the platform-agnostic shaping (size limits, safe
/// filenames, text previews) lives in
/// `HermesAttachmentLoaderSupport` (OpenBurnBarAssistantModels), shared
/// with the iOS back.
enum HermesAttachmentLoader {
    enum LoaderError: Error, LocalizedError {
        case unreadableFile(URL)
        case workspaceUnavailable
        case tooLarge(name: String, kind: HermesAttachmentKind, byteSize: Int)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let url):
                return "Could not read \(url.lastPathComponent)."
            case .workspaceUnavailable:
                return "Chat workspace folder is unavailable."
            case .tooLarge(let name, let kind, let byteSize):
                return "\(name) is too large (\(HermesAttachmentEncoder.formatBytes(byteSize))) for an inline \(kind.rawValue) attachment."
            }
        }
    }

    /// Imports a file from disk into the workspace `attachments/` folder.
    /// The original file is left untouched.
    static func importFile(
        at url: URL,
        intoWorkspace workspaceURL: URL
    ) throws -> HermesAttachment {
        let fm = FileManager.default
        let attachmentsDir = workspaceURL.appendingPathComponent("attachments", isDirectory: true)
        try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }

        let attrs = try fm.attributesOfItem(atPath: url.path)
        let byteSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let displayName = url.lastPathComponent
        let mimeType = mimeType(for: url)
        let kind = HermesAttachmentKind.infer(mimeType: mimeType, fileName: displayName)

        try enforceSizeLimit(name: displayName, kind: kind, byteSize: byteSize)

        let attachmentID = UUID().uuidString
        let safeName = HermesAttachmentLoaderSupport.safeFilename(displayName)
        let storedRelative = "attachments/\(attachmentID)-\(safeName)"
        let storedURL = workspaceURL.appendingPathComponent(storedRelative)

        if fm.fileExists(atPath: storedURL.path) {
            try? fm.removeItem(at: storedURL) // try?-ok(stale collision cleanup)
        }
        try fm.copyItem(at: url, to: storedURL)

        let preview = HermesAttachmentLoaderSupport.textPreview(forKind: kind, fileURL: storedURL)
        let thumbnail = makeThumbnail(forKind: kind, fileURL: storedURL)

        return HermesAttachment(
            id: attachmentID,
            kind: kind,
            displayName: displayName,
            mimeType: mimeType,
            byteSize: byteSize,
            workspaceRelativePath: storedRelative,
            thumbnailPNG: thumbnail,
            extractedTextPreview: preview
        )
    }

    /// Imports an in-memory image (e.g. clipboard paste, drag-and-drop NSImage)
    /// by writing it as a PNG into the workspace.
    static func importImage(
        _ image: NSImage,
        suggestedName: String? = nil,
        intoWorkspace workspaceURL: URL
    ) throws -> HermesAttachment {
        let fm = FileManager.default
        let attachmentsDir = workspaceURL.appendingPathComponent("attachments", isDirectory: true)
        try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw LoaderError.unreadableFile(URL(fileURLWithPath: suggestedName ?? "pasted-image.png"))
        }

        let attachmentID = UUID().uuidString
        let displayName = suggestedName ?? "pasted-image-\(Int(Date().timeIntervalSince1970)).png"
        let safeName = HermesAttachmentLoaderSupport.safeFilename(displayName)
        let storedRelative = "attachments/\(attachmentID)-\(safeName)"
        let storedURL = workspaceURL.appendingPathComponent(storedRelative)
        try png.write(to: storedURL)

        let byteSize = png.count
        try enforceSizeLimit(name: displayName, kind: .image, byteSize: byteSize)
        let thumbnail = thumbnailPNG(from: image, maxSide: 96)

        return HermesAttachment(
            id: attachmentID,
            kind: .image,
            displayName: displayName,
            mimeType: "image/png",
            byteSize: byteSize,
            workspaceRelativePath: storedRelative,
            thumbnailPNG: thumbnail,
            extractedTextPreview: nil
        )
    }

    /// Loads the bytes for an attachment so the encoder can inline them.
    /// Returns `nil` when the file no longer exists (chat reopened on a
    /// different device, etc.) so the encoder can degrade to a workspace ref.
    static func loadAttachmentBytes(
        _ attachment: HermesAttachment,
        workspaceURL: URL
    ) -> Data? {
        let url = workspaceURL.appendingPathComponent(attachment.workspaceRelativePath)
        return try? Data(contentsOf: url) // try?-ok(missing file degrades to ref)
    }

    /// Absolute on-disk path for a stored attachment.
    static func absolutePath(
        for attachment: HermesAttachment,
        workspaceURL: URL
    ) -> String {
        workspaceURL.appendingPathComponent(attachment.workspaceRelativePath).path
    }

    // MARK: - Helpers

    private static func enforceSizeLimit(
        name: String,
        kind: HermesAttachmentKind,
        byteSize: Int
    ) throws {
        if byteSize > HermesAttachmentLoaderSupport.sizeLimit(for: kind) {
            throw LoaderError.tooLarge(name: name, kind: kind, byteSize: byteSize)
        }
    }

    private static func mimeType(for url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        return type?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func makeThumbnail(forKind kind: HermesAttachmentKind, fileURL: URL) -> Data? {
        switch kind {
        case .image:
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            return thumbnailPNG(from: image, maxSide: 96)
        case .pdf:
            guard let pdf = NSImage(contentsOf: fileURL) else { return nil }
            return thumbnailPNG(from: pdf, maxSide: 96)
        default:
            return nil
        }
    }

    private static func thumbnailPNG(from image: NSImage, maxSide: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1.0, maxSide / max(size.width, size.height))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        guard let tiff = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
