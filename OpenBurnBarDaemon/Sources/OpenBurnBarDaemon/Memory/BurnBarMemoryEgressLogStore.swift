#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// One content-free record per memory-purpose request on the loopback
/// gateway: who was asked, how much left and came back, under which
/// retention class, and whether the policy allowed it. Hash-chained so a
/// missing or edited line is detectable. No field ever carries prompt or
/// memory text.
public struct BurnBarMemoryEgressEntry: Codable, Hashable, Sendable {
    public var seq: Int
    public var ts: String
    public let purpose: String
    public let providerID: String
    public let modelID: String
    public let requestBytes: Int
    public let responseBytes: Int
    public let retention: String
    public let outcome: String
    public let code: String?
    public let latencyMs: Int
    public var prevHash: String
    public var hash: String

    public init(
        purpose: String,
        providerID: String,
        modelID: String,
        requestBytes: Int,
        responseBytes: Int,
        retention: String,
        outcome: String,
        code: String?,
        latencyMs: Int
    ) {
        self.seq = 0
        self.ts = ""
        self.purpose = purpose
        self.providerID = providerID
        self.modelID = modelID
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.retention = retention
        self.outcome = outcome
        self.code = code
        self.latencyMs = latencyMs
        self.prevHash = ""
        self.hash = ""
    }

    func canonicalDigest() throws -> String {
        var copy = self
        copy.hash = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(copy))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct BurnBarMemoryEgressVerification: Sendable {
    public let ok: Bool
    public let events: Int
    public let brokenAtSeq: Int?
}

public actor BurnBarMemoryEgressLogStore {
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultMemoryEgressEventsURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
        encoder.outputFormatting = [.sortedKeys]
    }

    public func append(_ entry: BurnBarMemoryEgressEntry) throws {
        var stamped = entry
        let previous = try entries().last
        stamped.seq = (previous?.seq ?? 0) + 1
        stamped.ts = Self.iso(now())
        stamped.prevHash = previous?.hash ?? ""
        stamped.hash = try stamped.canonicalDigest()
        let line = try encoder.encode(stamped) + Data("\n".utf8)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func entries() throws -> [BurnBarMemoryEgressEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return try text.split(separator: "\n").map { try decoder.decode(BurnBarMemoryEgressEntry.self, from: Data($0.utf8)) }
    }

    public func verify() throws -> BurnBarMemoryEgressVerification {
        let all = try entries()
        var previousHash = ""
        for entry in all {
            guard entry.prevHash == previousHash, try entry.canonicalDigest() == entry.hash else {
                return BurnBarMemoryEgressVerification(ok: false, events: all.count, brokenAtSeq: entry.seq)
            }
            previousHash = entry.hash
        }
        return BurnBarMemoryEgressVerification(ok: true, events: all.count, brokenAtSeq: nil)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
