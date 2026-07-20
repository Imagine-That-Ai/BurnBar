import Foundation

/// Cross-platform policy for the Linux chat transport seam.
///
/// macOS stores richer workspace attachments (including images, audio, and
/// video). Linux deliberately advertises only the formats that can be carried
/// through the current text gateway without silently pretending binary support.
public enum BurnBarChatAttachmentPolicy: Sendable {
    public static let maxBytes = 10 * 1024 * 1024
    public static let maxNameBytes = 240

    public static let allowedMimeTypes: Set<String> = [
        "text/plain",
        "text/markdown",
        "text/csv",
        "application/json",
        "application/pdf"
    ]

    public static func canonicalMimeType(fileName: String, mimeType: String?) -> String? {
        let normalizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeFileName(normalizedName) else { return nil }
        let inferred = inferredMimeType(fileName: normalizedName)
        let supplied = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let canonical = supplied.isEmpty || supplied == "application/octet-stream"
            ? inferred
            : allowedMimeTypes.contains(supplied) ? supplied : nil
        guard let canonical, allowedMimeTypes.contains(canonical) else { return nil }
        if let inferred, inferred != canonical { return nil }
        return canonical
    }

    public static func isSafeFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              fileName.utf8.count <= maxNameBytes,
              !fileName.contains("/"),
              !fileName.contains("\\") else { return false }
        return fileName.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func inferredMimeType(fileName: String) -> String? {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "txt": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "pdf": return "application/pdf"
        default: return nil
        }
    }
}
