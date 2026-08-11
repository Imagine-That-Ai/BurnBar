#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A small, authenticated pointer sent over the daemon socket when the original
/// Safari payload cannot fit beneath the daemon's 64 KiB request ceiling.
///
/// The path is minted only by the native appex. Consumers must still resolve it
/// through ``BurnBarSafariAppGroupPayloadResolver`` with an explicit trusted App
/// Group root; decoding this value alone never grants filesystem authority.
public struct BurnBarSafariAppGroupPayloadReference: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let kind = "openburnbar.safari.app-group-payload"

    public let version: Int
    public let kind: String
    public let filePath: String
    public let byteLength: Int
    public let sha256: String
    public let expiresAtUnixMillis: Int64

    public init(
        version: Int = Self.currentVersion,
        kind: String = Self.kind,
        filePath: String,
        byteLength: Int,
        sha256: String,
        expiresAtUnixMillis: Int64
    ) {
        self.version = version
        self.kind = kind
        self.filePath = filePath
        self.byteLength = byteLength
        self.sha256 = sha256
        self.expiresAtUnixMillis = expiresAtUnixMillis
    }

    public var expiresAt: Date {
        Date(timeIntervalSince1970: Double(expiresAtUnixMillis) / 1_000)
    }

    /// Exact JSON marker embedded in an RPC `params` or nested result value.
    public var markerValue: BurnBarJSONValue {
        .object([
            BurnBarSafariBridgeWire.appGroupPayloadMarkerKey: .object([
                "version": .number(Double(version)),
                "kind": .string(kind),
                "filePath": .string(filePath),
                "byteLength": .number(Double(byteLength)),
                "sha256": .string(sha256),
                "expiresAtUnixMillis": .number(Double(expiresAtUnixMillis))
            ])
        ])
    }

    public static func decodeMarker(from value: BurnBarJSONValue) throws -> Self {
        guard case .object(let outer) = value,
              Set(outer.keys) == [BurnBarSafariBridgeWire.appGroupPayloadMarkerKey],
              case .object(let raw)? = outer[BurnBarSafariBridgeWire.appGroupPayloadMarkerKey],
              Set(raw.keys) == [
                  "version", "kind", "filePath", "byteLength", "sha256", "expiresAtUnixMillis"
              ],
              let version = exactInteger(raw["version"]),
              let kind = string(raw["kind"]),
              let filePath = string(raw["filePath"]),
              let byteLength = exactInteger(raw["byteLength"]),
              let sha256 = string(raw["sha256"]),
              let expiresAtUnixMillis = exactInt64(raw["expiresAtUnixMillis"]) else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_app_group_payload_reference",
                message: "Safari App Group payload reference is malformed."
            )
        }
        return Self(
            version: version,
            kind: kind,
            filePath: filePath,
            byteLength: byteLength,
            sha256: sha256,
            expiresAtUnixMillis: expiresAtUnixMillis
        )
    }

    private static func string(_ value: BurnBarJSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func exactInteger(_ value: BurnBarJSONValue?) -> Int? {
        guard case .number(let value)? = value,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    private static func exactInt64(_ value: BurnBarJSONValue?) -> Int64? {
        guard case .number(let value)? = value,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int64.min),
              value <= Double(Int64.max) else {
            return nil
        }
        return Int64(value)
    }
}

public enum BurnBarSafariAppGroupPayloadError: Error, LocalizedError, Equatable, Sendable {
    case appGroupUnavailable
    case invalidReference
    case pathOutsideTrustedRoot
    case symbolicLinkRejected
    case fileUnavailable
    case invalidFileType
    case invalidOwner
    case insecurePermissions
    case expired
    case oversized
    case lengthMismatch
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "The OpenBurnBar App Group container is unavailable."
        case .invalidReference:
            return "The Safari App Group payload reference is invalid."
        case .pathOutsideTrustedRoot:
            return "The Safari payload path is outside the trusted App Group root."
        case .symbolicLinkRejected:
            return "Symbolic links are not accepted for Safari App Group payloads."
        case .fileUnavailable:
            return "The referenced Safari App Group payload is unavailable."
        case .invalidFileType:
            return "The referenced Safari App Group payload is not a regular file."
        case .invalidOwner:
            return "The referenced Safari App Group payload has an unexpected owner."
        case .insecurePermissions:
            return "The referenced Safari App Group payload permissions are too broad."
        case .expired:
            return "The referenced Safari App Group payload has expired."
        case .oversized:
            return "The referenced Safari App Group payload exceeds the size limit."
        case .lengthMismatch:
            return "The referenced Safari App Group payload length does not match its declaration."
        case .digestMismatch:
            return "The referenced Safari App Group payload digest does not match its declaration."
        }
    }
}

public enum BurnBarSafariSharedContainer {
    public static let appGroupIdentifier = "group.com.openburnbar.app"

    public static func liveRoot(fileManager: FileManager = .default) -> URL? {
        #if canImport(Darwin)
        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )?.standardizedFileURL.resolvingSymlinksInPath()
        #else
        nil
        #endif
    }
}

/// Writes socket-oversized payloads into the App Group with owner-only
/// permissions and returns a short-lived, content-addressed reference.
public struct BurnBarSafariAppGroupPayloadStore: Sendable {
    public let trustedRoot: URL
    public let lifetime: TimeInterval
    private let fileManager: FileManager

    public init(
        trustedRoot: URL,
        lifetime: TimeInterval = 5 * 60,
        fileManager: FileManager = .default
    ) {
        self.trustedRoot = trustedRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.lifetime = min(max(lifetime, 1), 15 * 60)
        self.fileManager = fileManager
    }

    public static func live(fileManager: FileManager = .default) throws -> Self {
        guard let root = BurnBarSafariSharedContainer.liveRoot(fileManager: fileManager) else {
            throw BurnBarSafariAppGroupPayloadError.appGroupUnavailable
        }
        return Self(trustedRoot: root, fileManager: fileManager)
    }

    public func store(
        _ data: Data,
        now: Date = Date()
    ) throws -> BurnBarSafariAppGroupPayloadReference {
        guard !data.isEmpty,
              data.count <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes else {
            throw BurnBarSafariAppGroupPayloadError.oversized
        }

        let directory = trustedRoot
            .appendingPathComponent("SafariBridge", isDirectory: true)
            .appendingPathComponent("Payloads", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let fileURL = directory
            .appendingPathComponent("\(UUID().uuidString.lowercased()).payload", isDirectory: false)
            .standardizedFileURL
        guard Self.isContained(fileURL, by: trustedRoot) else {
            throw BurnBarSafariAppGroupPayloadError.pathOutsideTrustedRoot
        }

        try data.write(to: fileURL, options: [.atomic])
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw error
        }

        return BurnBarSafariAppGroupPayloadReference(
            filePath: fileURL.resolvingSymlinksInPath().path,
            byteLength: data.count,
            sha256: Self.sha256Hex(data),
            expiresAtUnixMillis: Int64((now.addingTimeInterval(lifetime).timeIntervalSince1970 * 1_000).rounded())
        )
    }

    /// Best-effort cleanup for a reference that could not be handed to the
    /// daemon after it was written. Only exact, canonical files inside this
    /// store's trusted root are eligible, so callers cannot turn cleanup into
    /// an arbitrary-path deletion primitive.
    public func discard(_ reference: BurnBarSafariAppGroupPayloadReference) {
        guard reference.version == BurnBarSafariAppGroupPayloadReference.currentVersion,
              reference.kind == BurnBarSafariAppGroupPayloadReference.kind else {
            return
        }
        let lexicalURL = URL(fileURLWithPath: reference.filePath).standardizedFileURL
        guard Self.isContained(lexicalURL, by: trustedRoot),
              lexicalURL.pathExtension == "payload" else {
            return
        }
        try? fileManager.removeItem(at: lexicalURL)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isContained(_ child: URL, by root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }
}

/// One-shot resolver shared by the native appex and daemon Safari handler.
///
/// Security invariants:
/// - the caller supplies the trusted App Group root explicitly;
/// - lexical and symlink-resolved paths must both remain beneath that root;
/// - the payload must be a same-user regular, non-symlink file with 0600-or-
///   stricter permissions;
/// - declared length, 12 MiB ceiling, expiry, and streamed SHA-256 all match;
/// - successful reads delete the file, making references non-replayable;
/// - expired and integrity-invalid in-root files are deleted on rejection.
public struct BurnBarSafariAppGroupPayloadResolver: Sendable {
    public let trustedRoot: URL
    private let fileManager: FileManager

    public init(trustedRoot: URL, fileManager: FileManager = .default) {
        self.trustedRoot = trustedRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    public func resolve(
        _ reference: BurnBarSafariAppGroupPayloadReference,
        now: Date = Date()
    ) throws -> Data {
        guard reference.version == BurnBarSafariAppGroupPayloadReference.currentVersion,
              reference.kind == BurnBarSafariAppGroupPayloadReference.kind,
              reference.byteLength > 0,
              reference.byteLength <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes,
              reference.sha256.count == 64,
              reference.sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
            throw BurnBarSafariAppGroupPayloadError.invalidReference
        }

        let lexicalURL = URL(fileURLWithPath: reference.filePath, isDirectory: false)
            .standardizedFileURL
        guard BurnBarSafariAppGroupPayloadStore.isContained(lexicalURL, by: trustedRoot) else {
            throw BurnBarSafariAppGroupPayloadError.pathOutsideTrustedRoot
        }

        if try isSymbolicLink(at: lexicalURL) {
            try? fileManager.removeItem(at: lexicalURL)
            throw BurnBarSafariAppGroupPayloadError.symbolicLinkRejected
        }

        let canonicalURL = lexicalURL.resolvingSymlinksInPath()
        guard BurnBarSafariAppGroupPayloadStore.isContained(canonicalURL, by: trustedRoot) else {
            throw BurnBarSafariAppGroupPayloadError.pathOutsideTrustedRoot
        }

        guard fileManager.fileExists(atPath: lexicalURL.path) else {
            throw BurnBarSafariAppGroupPayloadError.fileUnavailable
        }
        let resourceValues = try lexicalURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard resourceValues.isSymbolicLink != true else {
            try? fileManager.removeItem(at: lexicalURL)
            throw BurnBarSafariAppGroupPayloadError.symbolicLinkRejected
        }
        guard resourceValues.isRegularFile == true else {
            throw BurnBarSafariAppGroupPayloadError.invalidFileType
        }

        let attributes = try fileManager.attributesOfItem(atPath: lexicalURL.path)
        try validateOwner(attributes)
        guard let rawPermissions = attributes[.posixPermissions] as? NSNumber else {
            throw BurnBarSafariAppGroupPayloadError.insecurePermissions
        }
        let permissions = rawPermissions.intValue & 0o777
        guard permissions & ~0o600 == 0, permissions & 0o400 != 0 else {
            throw BurnBarSafariAppGroupPayloadError.insecurePermissions
        }

        guard reference.expiresAt > now else {
            try? fileManager.removeItem(at: lexicalURL)
            throw BurnBarSafariAppGroupPayloadError.expired
        }
        guard resourceValues.fileSize == reference.byteLength else {
            try? fileManager.removeItem(at: lexicalURL)
            throw BurnBarSafariAppGroupPayloadError.lengthMismatch
        }

        let (data, digest) = try readOnceAndHash(lexicalURL)
        guard data.count == reference.byteLength else {
            try? fileManager.removeItem(at: lexicalURL)
            throw BurnBarSafariAppGroupPayloadError.lengthMismatch
        }
        guard Self.constantTimeEqual(digest, reference.sha256) else {
            try? fileManager.removeItem(at: lexicalURL)
            throw BurnBarSafariAppGroupPayloadError.digestMismatch
        }

        try fileManager.removeItem(at: lexicalURL)
        return data
    }

    private func readOnceAndHash(_ url: URL) throws -> (Data, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var output = Data()
        output.reserveCapacity(min(
            BurnBarSafariBridgeWire.maximumChunkedPayloadBytes,
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        ))
        var hasher = SHA256()

        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            guard output.count + chunk.count <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes else {
                throw BurnBarSafariAppGroupPayloadError.oversized
            }
            hasher.update(data: chunk)
            output.append(chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (output, digest)
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                throw BurnBarSafariAppGroupPayloadError.fileUnavailable
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (metadata.st_mode & S_IFMT) == S_IFLNK
        #else
        return try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        #endif
    }

    private func validateOwner(_ attributes: [FileAttributeKey: Any]) throws {
        #if canImport(Darwin) || canImport(Glibc)
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == geteuid() else {
            throw BurnBarSafariAppGroupPayloadError.invalidOwner
        }
        #else
        _ = attributes
        #endif
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= l ^ r
        }
        return difference == 0
    }
}
