import Foundation
import AppKit
import OpenBurnBarCore
import UniformTypeIdentifiers

/// Loads files from disk / `NSImage` into the chat workspace and produces
/// `HermesAttachment` metadata. Mirrors the iOS loader of the same name so
/// the macOS / iOS / iPadOS surfaces produce identical attachments.
enum HermesAttachmentLoader {
    enum LoaderError: Error, LocalizedError {
        case unreadableFile(URL)
        case workspaceUnavailable
        case tooLarge(name: String, kind: HermesAttachmentKind, byteSize: Int)
        case unsafeAttachment(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let url):
                return "Could not read \(url.lastPathComponent)."
            case .workspaceUnavailable:
                return "Chat workspace folder is unavailable."
            case .tooLarge(let name, let kind, let byteSize):
                return "\(name) is too large (\(HermesAttachmentEncoder.formatBytes(byteSize))) for an inline \(kind.rawValue) attachment."
            case .unsafeAttachment(let name, let reason):
                return "\(name) cannot be opened as an agent attachment: \(reason)"
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

        // T-ATT-05 — port of the iOS agent-import safe-render block plus
        // content-sniffing. A mislabeled blob (e.g. HTML/script bytes wearing a
        // `.png` name and `image/*` MIME) must not be imported and later
        // rendered as a different, benign-looking type in the Mercury preview
        // path. We read the file's leading bytes for the sniff so the byte
        // content — not just the attacker-controlled extension/MIME — gates
        // admission.
        let headBytes = leadingBytes(of: url, count: contentSniffByteCount)
        try enforceSafeAttachmentForAgentImport(
            name: displayName,
            mimeType: mimeType,
            byteSize: byteSize,
            headBytes: headBytes
        )
        try enforceSizeLimit(name: displayName, kind: kind, byteSize: byteSize)

        let attachmentID = UUID().uuidString
        let safeName = safeFilename(displayName)
        let storedRelative = "attachments/\(attachmentID)-\(safeName)"
        let storedURL = workspaceURL.appendingPathComponent(storedRelative)

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
        let safeName = safeFilename(displayName)
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
        return try? Data(contentsOf: url)
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

    /// Number of leading bytes read for the content-sniff. 512 matches the WHATWG
    /// MIME-sniffing resource size and is enough to detect the script/markup
    /// signatures we block plus the common image/PDF magic numbers.
    static let contentSniffByteCount = 512

    /// T-ATT-05 — Mac port of the iOS `enforceSafeAttachmentForAgentImport`
    /// safe-render block, strengthened with mime-vs-bytes content-sniffing. It
    /// rejects:
    ///   1. path-traversal / control-character filenames,
    ///   2. active-content MIME types and extensions (HTML, JS, SVG, shells, …),
    ///   3. blobs whose *bytes* sniff as active content (HTML/script/SVG) while
    ///      claiming a benign type (image/pdf/text), i.e. a mislabeled blob that
    ///      would otherwise be rendered as a different type, and
    ///   4. an image/MIME claim contradicted by the leading magic bytes.
    /// `headBytes` is the file's leading `contentSniffByteCount` bytes (may be
    /// nil/empty for an unreadable or zero-byte file). The function is pure given
    /// its inputs so the security decision is unit-testable without disk I/O.
    static func enforceSafeAttachmentForAgentImport(
        name: String,
        mimeType: String,
        byteSize: Int,
        headBytes: Data?
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed.contains("/") || trimmed.contains("\\") {
            throw LoaderError.unsafeAttachment(name: name, reason: "invalid filename")
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw LoaderError.unsafeAttachment(name: name, reason: "filename contains control characters")
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        let mediaType = mimeType.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let blockedMediaTypes: Set<String> = [
            "text/html",
            "text/javascript",
            "application/javascript",
            "application/ecmascript",
            "application/xhtml+xml",
            "application/xml",
            "text/xml",
            "image/svg+xml"
        ]
        let blockedExtensions: Set<String> = [
            "app", "applescript", "command", "dmg", "exe", "hta", "html", "js", "jse",
            "pkg", "ps1", "scpt", "sh", "svg", "terminal", "vbs", "workflow", "xhtml", "xml"
        ]
        if blockedMediaTypes.contains(mediaType) || blockedExtensions.contains(ext) {
            throw LoaderError.unsafeAttachment(name: name, reason: "active content is blocked")
        }
        if byteSize > HermesAttachmentLimits.maxGenericBytes {
            throw LoaderError.unsafeAttachment(name: name, reason: "file exceeds the maximum accepted size")
        }

        // Content-sniffing (mime-vs-bytes). If the actual bytes look like active
        // content (HTML/script/SVG) regardless of how the file is labeled, refuse
        // it — this catches a `.png`/`image/png` blob whose bytes are really an
        // HTML document or `<svg onload=…>`.
        if let head = headBytes, !head.isEmpty {
            if Self.bytesSniffAsActiveContent(head) {
                throw LoaderError.unsafeAttachment(
                    name: name,
                    reason: "file contents are active markup/script and cannot be rendered safely"
                )
            }
            // A blob that claims to be an image but whose magic bytes match no
            // known raster/vector image format is a type mismatch — refuse it so
            // it cannot be force-rendered as an image.
            if mediaType.hasPrefix("image/"), !Self.bytesLookLikeKnownImage(head) {
                throw LoaderError.unsafeAttachment(
                    name: name,
                    reason: "image bytes do not match the declared image type"
                )
            }
        }
    }

    /// Detects active markup/script content from leading bytes (BOM-tolerant,
    /// case-insensitive). Mirrors the WHATWG markup-sniff heuristics for the
    /// signatures we treat as dangerous to render. Pure.
    static func bytesSniffAsActiveContent(_ data: Data) -> Bool {
        // Strip a leading UTF-8/UTF-16 BOM and ASCII whitespace before matching.
        var bytes = [UInt8](data.prefix(contentSniffByteCount))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D || first == 0x0C {
            bytes.removeFirst()
        }
        guard let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) else {
            return false
        }
        let lowered = text.lowercased()
        let activeMarkers = [
            "<!doctype html", "<html", "<head", "<body", "<script",
            "<svg", "<iframe", "<?xml", "<!entity", "javascript:", "<a "
        ]
        return activeMarkers.contains { lowered.contains($0) }
    }

    /// Returns `true` when the leading bytes match a known raster image magic
    /// number (PNG, JPEG, GIF, BMP, WEBP/RIFF, HEIC/HEIF, TIFF). SVG is
    /// deliberately excluded — it is active markup and handled by the active
    /// content block above. Pure.
    static func bytesLookLikeKnownImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        func startsWith(_ prefix: [UInt8]) -> Bool { bytes.starts(with: prefix) }
        if startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true } // PNG
        if startsWith([0xFF, 0xD8, 0xFF]) { return true } // JPEG
        if startsWith([0x47, 0x49, 0x46, 0x38]) { return true } // GIF8
        if startsWith([0x42, 0x4D]) { return true } // BMP
        if startsWith([0x49, 0x49, 0x2A, 0x00]) || startsWith([0x4D, 0x4D, 0x00, 0x2A]) { return true } // TIFF
        if startsWith([0x52, 0x49, 0x46, 0x46]), bytes.count >= 12,
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true } // RIFF…WEBP
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return true } // ……ftyp… (HEIC/HEIF/AVIF)
        return false
    }

    /// Reads up to `count` leading bytes from a file without mapping the whole
    /// thing. Returns nil for a missing/unreadable/empty file.
    static func leadingBytes(of url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: count)
        return (data?.isEmpty == false) ? data : nil
    }

    private static func mimeType(for url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        return type?.preferredMIMEType ?? "application/octet-stream"
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
