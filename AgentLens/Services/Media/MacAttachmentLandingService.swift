import Darwin
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarKernel
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

    // AUDIT(@unchecked Sendable): both tables are guarded by `lock` on every access.
    // Landing runs off the main actor from the attachment receive path while the UI
    // drains `pending`, so this is genuinely concurrent, not just a diagnostic.
    // sendable-allowlist: foundation-sdk-shim
    private final class LandingStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var landedByDigest: [String: URL] = [:]
        private var pending: [LandedFile] = []

        func landedURL(forDigest digest: String) -> URL? {
            lock.lock(); defer { lock.unlock() }
            return landedByDigest[digest]
        }

        func recordLanded(digest: String, url: URL) {
            lock.lock(); defer { lock.unlock() }
            landedByDigest[digest] = url
        }

        func appendPending(_ file: LandedFile) {
            lock.lock(); defer { lock.unlock() }
            pending.append(file)
        }

        func drainPending() -> [LandedFile] {
            lock.lock(); defer { lock.unlock() }
            let drained = pending
            pending.removeAll()
            return drained
        }

        func snapshotPending() -> [LandedFile] {
            lock.lock(); defer { lock.unlock() }
            return pending
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            landedByDigest.removeAll()
            pending.removeAll()
        }
    }

    private static let state = LandingStateBox()

    static func resetForTests() {
        state.removeAll()
    }

    static func takePending() -> [LandedFile] {
        state.drainPending()
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
        try assertContained(candidate, roots: roots)
        return candidate
    }

    /// Contain the full relative or absolute path against workspace / Drop roots.
    /// `../` and absolute paths outside roots fail closed. Returns only a
    /// contained URL that exists on disk.
    static func containedExistingFile(path: String, roots: [URL]) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { throw Error.containment }
        let expandedTilde = (trimmed as NSString).expandingTildeInPath
        let isAbsolute = expandedTilde.hasPrefix("/")
        if !isAbsolute {
            guard !trimmed.split(separator: "/").contains("..") else { throw Error.pathTraversal }
            for root in roots {
                let candidate = root.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
                do {
                    try assertContained(candidate, roots: [root])
                } catch {
                    continue
                }
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                return candidate
            }
            throw Error.containment
        }
        let candidate = URL(fileURLWithPath: expandedTilde).standardizedFileURL
        if candidate.pathComponents.contains("..") { throw Error.pathTraversal }
        try assertContained(candidate, roots: roots)
        guard FileManager.default.fileExists(atPath: candidate.path) else { throw Error.missingSource }
        return candidate
    }

    private static func assertContained(_ candidate: URL, roots: [URL]) throws {
        let standardized = candidate.standardizedFileURL
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if standardized.path == rootPath || standardized.path.hasPrefix(prefix) {
                return
            }
        }
        throw Error.containment
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
        let declared: String
        let verified: String
        let opened: String
        do {
            declared = try ContentBlake3.parse(declaredContentBlake3)
            verified = try ContentBlake3.parse(verifiedDigest)
            opened = try ContentBlake3.hashFile(at: plaintextURL)
        } catch {
            try? FileManager.default.removeItem(at: plaintextURL) // try?-ok(best-effort failed-open cleanup)
            throw Error.digestMismatch
        }
        // One blake3: declared (advertised) == iroh/cloud verified == hash of opened plaintext.
        guard declared == verified, declared == opened else {
            try? FileManager.default.removeItem(at: plaintextURL) // try?-ok(best-effort digest-mismatch cleanup)
            throw Error.digestMismatch
        }
        if let existing = state.landedURL(forDigest: verified), FileManager.default.fileExists(atPath: existing.path) {
            return LandedFile(url: existing, contentBlake3: verified, displayName: sanitizeFilename(filename))
        }
        let dest = try containedURL(filename: filename, roots: roots)
        if dest.path != plaintextURL.path {
            try? FileManager.default.removeItem(at: dest) // try?-ok(best-effort replace of existing dest)
            try FileManager.default.copyItem(at: plaintextURL, to: dest)
        }
        try applyQuarantine(dest)
        state.recordLanded(digest: verified, url: dest)
        let landed = LandedFile(url: dest, contentBlake3: verified, displayName: sanitizeFilename(filename))
        state.appendPending(landed)
        return landed
    }

    static func hermesAttachments(from landed: [LandedFile], workspaceRoot: URL) -> [HermesAttachment] {
        landed.map { item in
            let relative = item.url.path.replacingOccurrences(of: workspaceRoot.path + "/", with: "")
            return HermesAttachment(
                kind: .generic,
                displayName: item.displayName,
                mimeType: "application/octet-stream",
                byteSize: (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? 0, // try?-ok(display size is advisory)
                workspaceRelativePath: relative
            )
        }
    }
}

/// Mac product path: stream + FileSealAEAD.sealChunk, await each PUT, then compose.
enum MacBurnbarAttachmentUploadClient {
    static func uploadFile(fileURL: URL, deviceId: String) async throws -> CLIAgentMissionAttachmentRef {
        let byteCount = Int64(
            (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        )
        let digest = try ContentBlake3.hashFile(at: fileURL)
        let begun = try await ComputerUseSecurityCallableClient.beginBurnbarAttachment(
            byteCount: byteCount,
            contentBlake3: digest,
            deviceId: deviceId
        )
        let contentKey = try FileSealAEAD.mintContentKey()
        let header = FileSealAEAD.Header(
            attachmentId: begun.id,
            totalChunks: begun.chunkCount,
            plaintextSize: byteCount,
            contentBlake3: digest
        )
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() } // try?-ok(best-effort handle close)
        for index in 0..<begun.chunkCount {
            let part = handle.readData(ofLength: FileSealAEAD.chunkPlaintextBytes)
            let nonce = try FileSealAEAD.mintNonce()
            let sealed = try FileSealAEAD.sealChunk(
                plaintext: part,
                contentKey: contentKey,
                header: header,
                chunkIndex: UInt64(index),
                nonce: nonce
            )
            var wire = nonce
            wire.append(sealed.ciphertext)
            wire.append(sealed.tag)
            let partURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("burnbar-mac-part-\(begun.id)-\(index)")
            try wire.write(to: partURL)
            let signed = try await ComputerUseSecurityCallableClient.mintBurnbarAttachmentPartURL(
                id: begun.id,
                partIndex: index,
                contentLength: Int64(wire.count),
                deviceId: deviceId
            )
            try await putAwaiting(fileURL: partURL, signedURL: signed)
        }
        try await ComputerUseSecurityCallableClient.composeBurnbarAttachment(id: begun.id, deviceId: deviceId)
        try await ComputerUseSecurityCallableClient.finalizeBurnbarAttachment(id: begun.id, deviceId: deviceId)
        return CLIAgentMissionAttachmentRef(
            id: begun.id,
            contentBlake3: digest,
            displayName: fileURL.lastPathComponent,
            byteCount: byteCount,
            transport: "cloud",
            contentKeyBase64: contentKey.base64EncodedString()
        )
    }

    private static func putAwaiting(fileURL: URL, signedURL: URL) async throws {
        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let length = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0 // try?-ok(Content-Length is advisory)
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        request.setValue("0", forHTTPHeaderField: "x-goog-if-generation-match")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "OpenBurnBar.MacBurnbarAttachmentUpload",
                code: (response as? HTTPURLResponse)?.statusCode ?? 1,
                userInfo: [NSLocalizedDescriptionKey: "Attachment part PUT failed."]
            )
        }
    }
}
