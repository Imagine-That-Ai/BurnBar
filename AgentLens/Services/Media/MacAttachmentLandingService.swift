import Darwin
import Foundation
import OpenBurnBarMedia

/// Lands a verified attachment into a workspace / Drop / `.burnbar/attachments` prefix.
/// Idempotence key is the verified digest of opened plaintext, never a ticket string.
enum MacAttachmentLandingService {
    enum Error: Swift.Error, Equatable {
        case missingContentKey
        case digestMismatch
        case pathTraversal
        case containment
        case missingSource
    }

    struct LandedFile: Equatable {
        var url: URL
        var contentBlake3: String
        var displayName: String
    }

    private static var landedByDigest: [String: URL] = [:]
    private static var pending: [LandedFile] = []

    static func resetForTests() {
        landedByDigest.removeAll()
        pending.removeAll()
    }

    static func takePending() -> [LandedFile] {
        let copy = pending
        pending.removeAll()
        return copy
    }

    static func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let last = (trimmed as NSString).lastPathComponent
        if last.isEmpty || last == "." || last == ".." { return "attachment.bin" }
        return last
    }

    static func containedURL(filename: String, roots: [URL]) throws -> URL {
        let safe = sanitizeFilename(filename)
        guard !safe.contains("..") else { throw Error.pathTraversal }
        guard let root = roots.first else { throw Error.containment }
        let candidate = root.appendingPathComponent(safe, isDirectory: false).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            || candidate.deletingLastPathComponent().path == root.standardizedFileURL.path else {
            throw Error.containment
        }
        return candidate
    }

    static func land(
        plaintextURL: URL,
        declaredContentBlake3: String,
        filename: String,
        roots: [URL],
        contentKey: Data?,
        applyQuarantine: (URL) throws -> Void = { url in
            let token = "0001;openburnbar;MacAttachmentLandingService;"
            _ = token.withCString { cstr in
                setxattr(url.path, "com.apple.quarantine", cstr, token.utf8.count, 0, 0)
            }
        },
        verifiedDigest: String
    ) throws -> LandedFile {
        guard contentKey != nil else { throw Error.missingContentKey }
        guard FileManager.default.fileExists(atPath: plaintextURL.path) else { throw Error.missingSource }
        let declared = declaredContentBlake3.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let verified = verifiedDigest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !declared.isEmpty, declared == verified else { throw Error.digestMismatch }
        if let existing = landedByDigest[verified], FileManager.default.fileExists(atPath: existing.path) {
            return LandedFile(url: existing, contentBlake3: verified, displayName: sanitizeFilename(filename))
        }
        let dest = try containedURL(filename: filename, roots: roots)
        if dest.path != plaintextURL.path {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: plaintextURL, to: dest)
        }
        try applyQuarantine(dest)
        landedByDigest[verified] = dest
        let landed = LandedFile(url: dest, contentBlake3: verified, displayName: sanitizeFilename(filename))
        pending.append(landed)
        return landed
    }

    static func hermesAttachments(from landed: [LandedFile], workspaceRoot: URL) -> [HermesAttachment] {
        landed.map { item in
            let relative = item.url.path.replacingOccurrences(of: workspaceRoot.path + "/", with: "")
            return HermesAttachment(
                kind: .generic,
                displayName: item.displayName,
                mimeType: "application/octet-stream",
                byteSize: (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? 0,
                workspaceRelativePath: relative
            )
        }
    }
}
