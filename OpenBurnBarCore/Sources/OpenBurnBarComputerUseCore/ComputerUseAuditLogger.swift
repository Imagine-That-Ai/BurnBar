import Foundation

/// Append-only writer that maintains the parent-hash chain for a
/// running Computer Use session. Pure I/O — the dispatcher hands an
/// already-built `ComputerUseAuditEntry` and the writer:
///   1. Validates `entry.parentEntryHashHex` matches the current head
///   2. Encodes the entry as canonical-JSON
///   3. Appends the JSON line + `\n` to the chain file
///   4. Re-hashes the just-written entry to advance the head
///
/// The writer is stateful (head hash + entry index). It is *not*
/// thread-safe by itself — wrap calls in the dispatcher's actor.
///
/// File layout (Phase 10 ship):
///
/// ```
/// ~/Library/Application Support/com.openburnbar.AgentLens/computer-use-audit/
///     {sessionId}/
///         manifest.json                  // session-start manifest (canonical JSON)
///         chain.jsonl                    // parent-hash chained entries
///         head.json                      // {index, hashHex, updatedAt}
///         screenshots/
///             {entryIndex}_{before|after}.png
/// ```
///
/// Screenshots live under `screenshots/` so the chain file stays
/// auditable in any text editor. The chain references screenshots only
/// by their content hash (Decision 8) so renaming the screenshot dir
/// cannot break chain validation.
public final class ComputerUseAuditLogger {
    public enum AuditLoggerError: Error, Sendable, Equatable {
        case directoryNotWritable
        case manifestAlreadyExists
        case chainHeadCorrupted
        case parentHashMismatch(expected: String, actual: String)
        case encodingFailed
    }

    public let sessionId: ComputerUseSessionID
    public let directory: URL
    public let macAppVersion: String

    private let fileManager: FileManager
    private let hasher: ComputerUseAuditHasher
    private(set) public var headHashHex: String
    private(set) public var nextEntryIndex: Int

    public init(
        sessionId: ComputerUseSessionID,
        baseDirectory: URL,
        macAppVersion: String,
        fileManager: FileManager = .default,
        hasher: ComputerUseAuditHasher = .current
    ) throws {
        self.sessionId = sessionId
        self.directory = baseDirectory.appendingPathComponent(sessionId.rawValue, isDirectory: true)
        self.macAppVersion = macAppVersion
        self.fileManager = fileManager
        self.hasher = hasher
        self.headHashHex = ComputerUseAuditHasher.genesisParentHashHex
        self.nextEntryIndex = 0

        try Self.ensureDirectoryExists(self.directory, fileManager: fileManager)
        try Self.ensureDirectoryExists(self.directory.appendingPathComponent("screenshots", isDirectory: true), fileManager: fileManager)
    }

    /// Write the session-start manifest, hash it, and seed the chain
    /// head. Idempotent only at the byte level — once a manifest is
    /// written, a second start attempt with a different manifest throws.
    public func beginSession(manifest: ComputerUseSessionManifest) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let encoded = try ComputerUseAuditHasher.canonicalJSONEncoder.encode(manifest)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let onDisk = try Data(contentsOf: manifestURL)
            if onDisk != encoded {
                throw AuditLoggerError.manifestAlreadyExists
            }
        } else {
            try encoded.write(to: manifestURL, options: .atomic)
        }
        headHashHex = hasher.hash(data: encoded)
        try writeHeadMarker()
    }

    /// Append an entry. Returns the resulting head hash so the
    /// dispatcher can attach it to outgoing `control.action.log` frames
    /// for the phone overlay.
    @discardableResult
    public func append(_ entry: ComputerUseAuditEntry) throws -> String {
        guard entry.entryIndex == nextEntryIndex else {
            throw AuditLoggerError.chainHeadCorrupted
        }
        guard entry.parentEntryHashHex == headHashHex else {
            throw AuditLoggerError.parentHashMismatch(
                expected: headHashHex,
                actual: entry.parentEntryHashHex
            )
        }
        let encoded = try ComputerUseAuditHasher.canonicalJSONEncoder.encode(entry)
        let chainURL = directory.appendingPathComponent("chain.jsonl")
        if !fileManager.fileExists(atPath: chainURL.path) {
            try Data().write(to: chainURL, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: chainURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded)
        try handle.write(contentsOf: Data([0x0A]))  // \n

        headHashHex = hasher.hash(data: encoded)
        nextEntryIndex += 1
        try writeHeadMarker()
        return headHashHex
    }

    /// Convenience: build the next entry from the typed action. The
    /// caller supplies the `approvedBy` value the gate decided on and an
    /// optional screenshot hash recorded by `MacScreenshotService`.
    public func makeEntry(
        for action: ComputerUseAction,
        timestamp: Date = Date(),
        approvalId: String? = nil,
        approvedBy: ComputerUseAuditEntry.ApprovedBy,
        scopeRuleId: String? = nil,
        denyReason: String? = nil,
        beforeScreenshotHashHex: String? = nil,
        afterScreenshotHashHex: String? = nil,
        macHostNodeId: String? = nil,
        scopeContext: ComputerUseScopeContext? = nil
    ) throws -> ComputerUseAuditEntry {
        let descriptorHash = try hasher.hash(action)
        return ComputerUseAuditEntry(
            sessionId: sessionId.rawValue,
            entryIndex: nextEntryIndex,
            timestamp: timestamp,
            actionKind: action.auditKind,
            actionSummary: action.executableSummary(forApproval: scopeContext),
            actionDescriptorHashHex: descriptorHash,
            beforeScreenshotHashHex: beforeScreenshotHashHex,
            afterScreenshotHashHex: afterScreenshotHashHex,
            approvalId: approvalId,
            approvedBy: approvedBy,
            scopeRuleId: scopeRuleId,
            denyReason: denyReason,
            parentEntryHashHex: headHashHex,
            macAppVersion: macAppVersion,
            macHostNodeId: macHostNodeId
        )
    }

    private func writeHeadMarker() throws {
        struct HeadMarker: Encodable {
            let index: Int
            let hashHex: String
            let updatedAt: Date
            let sessionId: String
            let schemaVersion: Int
        }
        let head = HeadMarker(
            index: nextEntryIndex,
            hashHex: headHashHex,
            updatedAt: Date(),
            sessionId: sessionId.rawValue,
            schemaVersion: ComputerUseAuditEntry.schemaVersion
        )
        let data = try ComputerUseAuditHasher.canonicalJSONEncoder.encode(head)
        let headURL = directory.appendingPathComponent("head.json")
        try data.write(to: headURL, options: .atomic)
    }

    private static func ensureDirectoryExists(_ url: URL, fileManager: FileManager) throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue { throw AuditLoggerError.directoryNotWritable }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
