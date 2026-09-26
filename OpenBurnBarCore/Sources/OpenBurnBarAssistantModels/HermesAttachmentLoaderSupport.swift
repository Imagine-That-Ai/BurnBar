import Foundation

/// Wave 3.4 union of the private file/byte helpers previously duplicated in
/// the macOS / iOS `HermesAttachmentLoader` twins. The loaders themselves
/// stay host-side (`HermesAttachmentLoader+AgentLens.swift` /
/// `HermesAttachmentLoader+Mobile.swift`) because every entry point is
/// platform-API-bound (`NSImage`/AppKit vs `UIImage`/PhotosPicker); only
/// the platform-agnostic shaping lives here so the two surfaces cannot
/// drift on limits, filenames, or text previews.
public enum HermesAttachmentLoaderSupport {
    /// Byte ceiling for an inline attachment of `kind`. Mirrors the switch
    /// both loader twins carried privately.
    public static func sizeLimit(for kind: HermesAttachmentKind) -> Int {
        switch kind {
        case .image: return HermesAttachmentLimits.maxImageBytes
        case .pdf: return HermesAttachmentLimits.maxImageBytes
        case .audio: return HermesAttachmentLimits.maxAudioBytes
        case .textDocument: return HermesAttachmentLimits.maxTextDocumentBytes
        case .video, .generic: return HermesAttachmentLimits.maxGenericBytes
        }
    }

    /// Strips a user-facing filename down to an 80-char
    /// alphanumerics-plus-`._-` stem safe to persist in the workspace.
    public static func safeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let trimmed = String(scalars).prefix(80)
        return trimmed.isEmpty ? "file" : String(trimmed)
    }

    /// First-4KB text preview for `.textDocument` attachments, `nil` for
    /// every other kind or when the stored file cannot be read.
    public static func textPreview(forKind kind: HermesAttachmentKind, fileURL: URL) -> String? {
        guard kind == .textDocument else { return nil }
        guard let data = try? Data(contentsOf: fileURL, options: [.alwaysMapped]) else { return nil }
        let head = data.prefix(HermesAttachmentLimits.textPreviewBytes)
        if let utf8 = String(data: head, encoding: .utf8) { return utf8 }
        if let latin1 = String(data: head, encoding: .isoLatin1) { return latin1 }
        return nil
    }
}
