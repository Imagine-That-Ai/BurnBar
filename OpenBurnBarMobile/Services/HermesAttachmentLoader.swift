import Foundation
import SwiftUI
import UIKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import OpenBurnBarCore

// MARK: - Mobile Hermes Attachment Loader

/// Builds `HermesAttachment` records from PhotosPicker, fileImporter, drag,
/// camera, and clipboard sources on iPhone and iPad. Mirrors the macOS
/// loader so the wire format stays identical regardless of platform.
enum HermesAttachmentLoader {
    enum LoaderError: Error, LocalizedError {
        case unreadableFile(String)
        case workspaceUnavailable
        case tooLarge(name: String, kind: HermesAttachmentKind, byteSize: Int)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let name):
                return "Could not read \(name)."
            case .workspaceUnavailable:
                return "Chat workspace folder is unavailable."
            case .tooLarge(let name, let kind, let byteSize):
                return "\(name) is too large (\(HermesAttachmentEncoder.formatBytes(byteSize))) for an inline \(kind.rawValue) attachment."
            }
        }
    }

    /// Imports a file URL (Files-app pick, drag from external app, camera
    /// capture saved to a tmp URL, etc.).
    static func importFileURL(
        _ url: URL,
        threadID: String = HermesAttachmentWorkspace.defaultThreadID
    ) throws -> HermesAttachment {
        guard let workspace = HermesAttachmentWorkspace.attachmentsRoot(threadID: threadID) else {
            throw LoaderError.workspaceUnavailable
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let byteSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let displayName = url.lastPathComponent
        let mimeType = mimeType(for: url)
        let kind = HermesAttachmentKind.infer(mimeType: mimeType, fileName: displayName)

        try enforceSizeLimit(name: displayName, kind: kind, byteSize: byteSize)

        let attachmentID = UUID().uuidString
        let safeName = safeFilename(displayName)
        let storedRelative = "attachments/\(attachmentID)-\(safeName)"
        let storedURL = workspace.appendingPathComponent(storedRelative)
        if fm.fileExists(atPath: storedURL.path) {
            try? fm.removeItem(at: storedURL)
        }
        try fm.copyItem(at: url, to: storedURL)

        let preview = makeTextPreview(forKind: kind, fileURL: storedURL)
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

    /// Imports raw image data (UIImage from PhotosPicker, camera, paste).
    static func importImage(
        _ image: UIImage,
        suggestedName: String? = nil,
        threadID: String = HermesAttachmentWorkspace.defaultThreadID
    ) throws -> HermesAttachment {
        guard let workspace = HermesAttachmentWorkspace.attachmentsRoot(threadID: threadID) else {
            throw LoaderError.workspaceUnavailable
        }
        let attachmentID = UUID().uuidString
        let baseName = suggestedName ?? "photo-\(Int(Date().timeIntervalSince1970)).jpg"
        let displayName = baseName.hasSuffix(".jpg") || baseName.hasSuffix(".jpeg") || baseName.hasSuffix(".png") || baseName.hasSuffix(".heic")
            ? baseName
            : "\(baseName).jpg"
        let safeName = safeFilename(displayName)
        let storedRelative = "attachments/\(attachmentID)-\(safeName)"
        let storedURL = workspace.appendingPathComponent(storedRelative)

        // Encode JPEG at 0.85 quality — good balance between fidelity and
        // payload size for vision models.
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw LoaderError.unreadableFile(displayName)
        }
        try enforceSizeLimit(name: displayName, kind: .image, byteSize: data.count)
        try data.write(to: storedURL)

        let thumbnail = thumbnailJPEG(from: image, maxSide: 96)

        return HermesAttachment(
            id: attachmentID,
            kind: .image,
            displayName: displayName,
            mimeType: "image/jpeg",
            byteSize: data.count,
            workspaceRelativePath: storedRelative,
            thumbnailPNG: thumbnail,
            extractedTextPreview: nil
        )
    }

    /// Imports a `PhotosPickerItem` by streaming its `Transferable` data into
    /// the workspace. Handles images, livePhotos (image part), and movies.
    static func importPhotosPickerItem(
        _ item: PhotosPickerItem,
        threadID: String = HermesAttachmentWorkspace.defaultThreadID
    ) async throws -> HermesAttachment {
        guard let workspace = HermesAttachmentWorkspace.attachmentsRoot(threadID: threadID) else {
            throw LoaderError.workspaceUnavailable
        }

        // Prefer raw Data — works for both images and short videos. For very
        // large videos PhotosPicker lets us stream a URL via .movie; we try
        // that path when raw data fails.
        if let data = try await item.loadTransferable(type: Data.self) {
            let displayName = item.itemIdentifier.map { "photo-\($0.suffix(8)).jpg" } ?? "photo-\(Int(Date().timeIntervalSince1970)).jpg"
            return try importData(data, displayName: displayName, threadID: threadID)
        }
        if let movieURL = try await item.loadTransferable(type: PhotoPickerMovie.self)?.url {
            return try importFileURL(movieURL, threadID: threadID)
        }
        // Couldn't read raw data or a file URL — surface a friendly error.
        throw LoaderError.unreadableFile("photo")
    }

    /// Imports raw bytes with a chosen filename (clipboard paste of an image,
    /// camera capture re-encoded by the picker, etc.).
    static func importData(
        _ data: Data,
        displayName: String,
        threadID: String = HermesAttachmentWorkspace.defaultThreadID
    ) throws -> HermesAttachment {
        guard let workspace = HermesAttachmentWorkspace.attachmentsRoot(threadID: threadID) else {
            throw LoaderError.workspaceUnavailable
        }
        let attachmentID = UUID().uuidString
        let safeName = safeFilename(displayName)
        let storedRelative = "attachments/\(attachmentID)-\(safeName)"
        let storedURL = workspace.appendingPathComponent(storedRelative)
        try data.write(to: storedURL)

        let mime = mimeType(forFileName: displayName)
        let kind = HermesAttachmentKind.infer(mimeType: mime, fileName: displayName)
        try enforceSizeLimit(name: displayName, kind: kind, byteSize: data.count)

        let preview = kind == .textDocument ? String(data: data.prefix(HermesAttachmentLimits.textPreviewBytes), encoding: .utf8) : nil
        let thumbnail = kind == .image ? UIImage(data: data).flatMap { thumbnailJPEG(from: $0, maxSide: 96) } : nil

        return HermesAttachment(
            id: attachmentID,
            kind: kind,
            displayName: displayName,
            mimeType: mime,
            byteSize: data.count,
            workspaceRelativePath: storedRelative,
            thumbnailPNG: thumbnail,
            extractedTextPreview: preview
        )
    }

    // MARK: - Helpers

    private static func enforceSizeLimit(
        name: String,
        kind: HermesAttachmentKind,
        byteSize: Int
    ) throws {
        let limit: Int
        switch kind {
        case .image: limit = HermesAttachmentLimits.maxImageBytes
        case .pdf: limit = HermesAttachmentLimits.maxImageBytes
        case .audio: limit = HermesAttachmentLimits.maxAudioBytes
        case .textDocument: limit = HermesAttachmentLimits.maxTextDocumentBytes
        case .video, .generic: limit = HermesAttachmentLimits.maxGenericBytes
        }
        if byteSize > limit {
            throw LoaderError.tooLarge(name: name, kind: kind, byteSize: byteSize)
        }
    }

    private static func mimeType(for url: URL) -> String {
        mimeType(forFileName: url.lastPathComponent)
    }

    private static func mimeType(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        if ext.isEmpty { return "application/octet-stream" }
        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func safeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let trimmed = String(scalars).prefix(80)
        return trimmed.isEmpty ? "file" : String(trimmed)
    }

    private static func makeTextPreview(forKind kind: HermesAttachmentKind, fileURL: URL) -> String? {
        guard kind == .textDocument else { return nil }
        guard let data = try? Data(contentsOf: fileURL, options: [.alwaysMapped]) else { return nil }
        let head = data.prefix(HermesAttachmentLimits.textPreviewBytes)
        if let utf8 = String(data: head, encoding: .utf8) { return utf8 }
        if let latin1 = String(data: head, encoding: .isoLatin1) { return latin1 }
        return nil
    }

    private static func makeThumbnail(forKind kind: HermesAttachmentKind, fileURL: URL) -> Data? {
        switch kind {
        case .image:
            guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
            return thumbnailJPEG(from: image, maxSide: 96)
        case .pdf:
            // Lightweight PDF thumbnail using the first page.
            return pdfFirstPageThumbnail(url: fileURL, maxSide: 96)
        default:
            return nil
        }
    }

    private static func thumbnailJPEG(from image: UIImage, maxSide: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1.0, maxSide / max(size.width, size.height))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }

    private static func pdfFirstPageThumbnail(url: URL, maxSide: CGFloat) -> Data? {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else {
            return nil
        }
        let mediaBox = page.getBoxRect(.mediaBox)
        let scale = min(1.0, maxSide / max(mediaBox.width, mediaBox.height))
        let target = CGSize(width: max(1, mediaBox.width * scale), height: max(1, mediaBox.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            ctx.cgContext.translateBy(x: 0, y: target.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.drawPDFPage(page)
        }
        return image.jpegData(compressionQuality: 0.7)
    }
}

// MARK: - PhotosPicker Movie Transferable

/// Shim type used to pull a movie URL out of `PhotosPickerItem` when the
/// user picks a video.
struct PhotoPickerMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("hermes-\(UUID().uuidString)-\(received.file.lastPathComponent)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PhotoPickerMovie(url: copy)
        }
    }
}
