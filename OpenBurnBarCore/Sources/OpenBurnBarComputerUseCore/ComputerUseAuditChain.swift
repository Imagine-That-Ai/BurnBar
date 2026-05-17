import Foundation
import CryptoKit

/// One entry in the Computer Use audit chain. The field set is locked at
/// Phase 10 ship and never reordered — the chain hashes a canonical-JSON
/// serialization of this struct, so adding a field without bumping the
/// schema version would invalidate every chain on disk. Future schema
/// versions append fields and the validator dispatches by `schemaVersion`.
///
/// See `plans/2026-05-16-computer-use-master-plan.md` § Decision 8.
public struct ComputerUseAuditEntry: Codable, Hashable, Sendable {
    public static let schemaVersion: Int = 1

    public enum ApprovedBy: String, Codable, Sendable, Hashable, CaseIterable {
        case mac
        case phone
        case trustedScope = "trusted_scope"
        case step
        case denied
        case panic
    }

    public let schemaVersion: Int
    public let sessionId: String
    public let entryIndex: Int
    public let timestamp: Date
    public let actionKind: String
    public let actionSummary: String
    /// Canonical-JSON encoding of the action descriptor (one of the
    /// `ComputerUseAction` cases). Stored as a hex string of its hash
    /// rather than the full descriptor so screenshots / selectors / urls
    /// stay private at-rest — only the running Mac sees full action
    /// payloads in `~/Library/Application Support`.
    public let actionDescriptorHashHex: String
    public let beforeScreenshotHashHex: String?
    public let afterScreenshotHashHex: String?
    public let approvalId: String?
    public let approvedBy: ApprovedBy
    public let scopeRuleId: String?
    public let denyReason: String?
    public let parentEntryHashHex: String
    public let macAppVersion: String
    public let macHostNodeId: String?

    public init(
        sessionId: String,
        entryIndex: Int,
        timestamp: Date,
        actionKind: String,
        actionSummary: String,
        actionDescriptorHashHex: String,
        beforeScreenshotHashHex: String? = nil,
        afterScreenshotHashHex: String? = nil,
        approvalId: String? = nil,
        approvedBy: ApprovedBy,
        scopeRuleId: String? = nil,
        denyReason: String? = nil,
        parentEntryHashHex: String,
        macAppVersion: String,
        macHostNodeId: String? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.sessionId = sessionId
        self.entryIndex = entryIndex
        self.timestamp = timestamp
        self.actionKind = actionKind
        self.actionSummary = actionSummary
        self.actionDescriptorHashHex = actionDescriptorHashHex
        self.beforeScreenshotHashHex = beforeScreenshotHashHex
        self.afterScreenshotHashHex = afterScreenshotHashHex
        self.approvalId = approvalId
        self.approvedBy = approvedBy
        self.scopeRuleId = scopeRuleId
        self.denyReason = denyReason
        self.parentEntryHashHex = parentEntryHashHex
        self.macAppVersion = macAppVersion
        self.macHostNodeId = macHostNodeId
    }
}

/// Canonical-JSON encoder + hash function. Two requirements: keys are
/// sorted alphabetically and `Date` is encoded as a millisecond integer
/// so the chain re-hashes byte-identically across Swift compiler versions
/// (Decision 8 / Phase 10 acceptance gate 2).
///
/// Hash algorithm: SHA-256. The plan and the wire field names ("Blake3")
/// reflect the long-term intent to upgrade to BLAKE3 once `iroh-blobs`
/// exposes a Swift binding. The chain validator is hash-agnostic — it
/// re-hashes with the same primitive used at write time, controlled by
/// `ComputerUseAuditHasher.current`.
public struct ComputerUseAuditHasher: Sendable {
    public enum Algorithm: String, Codable, Sendable, Hashable, CaseIterable {
        case sha256
    }

    public static let current = ComputerUseAuditHasher(algorithm: .sha256)

    public let algorithm: Algorithm

    public init(algorithm: Algorithm) {
        self.algorithm = algorithm
    }

    /// Hex digest of a canonical-JSON encoding of `value`.
    public func hash<T: Encodable>(_ value: T) throws -> String {
        let data = try Self.canonicalJSONEncoder.encode(value)
        return hash(data: data)
    }

    public func hash(data: Data) -> String {
        switch algorithm {
        case .sha256:
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The empty parent hash used to seed chain start.
    public static let genesisParentHashHex: String = String(repeating: "0", count: 64)

    public static let canonicalJSONEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
            try container.encode(ms)
        }
        return encoder
    }()

    public static let canonicalJSONDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let ms = try container.decode(Int64.self)
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        return decoder
    }()
}

/// On-disk JSONL chain reader + validator. Pure; no AppKit, no file I/O
/// outside the supplied URL. Tested with golden fixtures in
/// `OpenBurnBarComputerUseCoreTests/AuditChainTests.swift`.
public struct ComputerUseAuditChain: Sendable {
    public struct ValidationResult: Sendable, Equatable {
        public let entryCount: Int
        public let isValid: Bool
        public let firstInvalidEntryIndex: Int?
        public let firstInvalidReason: InvalidReason?
        public let headHashHex: String?

        public init(
            entryCount: Int,
            isValid: Bool,
            firstInvalidEntryIndex: Int? = nil,
            firstInvalidReason: InvalidReason? = nil,
            headHashHex: String? = nil
        ) {
            self.entryCount = entryCount
            self.isValid = isValid
            self.firstInvalidEntryIndex = firstInvalidEntryIndex
            self.firstInvalidReason = firstInvalidReason
            self.headHashHex = headHashHex
        }
    }

    public enum InvalidReason: String, Sendable, Equatable {
        case parentHashMismatch = "parent_hash_mismatch"
        case unexpectedEntryIndex = "unexpected_entry_index"
        case decodeFailure = "decode_failure"
        case truncatedFile = "truncated_file"
        case unsupportedSchema = "unsupported_schema"
        case headHashMismatch = "head_hash_mismatch"
    }

    public let hasher: ComputerUseAuditHasher

    public init(hasher: ComputerUseAuditHasher = .current) {
        self.hasher = hasher
    }

    /// Walk a JSONL chain file at `url` and re-derive every entry's
    /// hash against its predecessor. Stops at the first mismatch and
    /// reports the failing index. If `expectedHeadHashHex` is supplied
    /// (typically from `head.json`), the walker compares the
    /// recomputed terminal head against it — this catches tampering of
    /// the *last* entry, which a parent-chain walk alone cannot detect
    /// (there's no successor entry to break against).
    public func validate(
        at url: URL,
        sessionManifestHashHex: String,
        expectedHeadHashHex: String? = nil
    ) throws -> ValidationResult {
        let raw = try Data(contentsOf: url)
        return validate(
            rawJSONLines: raw,
            sessionManifestHashHex: sessionManifestHashHex,
            expectedHeadHashHex: expectedHeadHashHex
        )
    }

    /// In-memory equivalent of `validate(at:)`. Useful for tests.
    public func validate(
        rawJSONLines: Data,
        sessionManifestHashHex: String,
        expectedHeadHashHex: String? = nil
    ) -> ValidationResult {
        guard let text = String(data: rawJSONLines, encoding: .utf8) else {
            return ValidationResult(entryCount: 0, isValid: false, firstInvalidReason: .decodeFailure)
        }
        var expectedIndex = 0
        var parentHashHex = sessionManifestHashHex
        var lineEntries: [ComputerUseAuditEntry] = []

        for (lineNumber, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let lineData = Data(line.utf8)
            let entry: ComputerUseAuditEntry
            do {
                entry = try ComputerUseAuditHasher.canonicalJSONDecoder
                    .decode(ComputerUseAuditEntry.self, from: lineData)
            } catch {
                return ValidationResult(
                    entryCount: lineEntries.count,
                    isValid: false,
                    firstInvalidEntryIndex: lineNumber,
                    firstInvalidReason: .decodeFailure
                )
            }
            if entry.schemaVersion != ComputerUseAuditEntry.schemaVersion {
                return ValidationResult(
                    entryCount: lineEntries.count,
                    isValid: false,
                    firstInvalidEntryIndex: entry.entryIndex,
                    firstInvalidReason: .unsupportedSchema
                )
            }
            if entry.entryIndex != expectedIndex {
                return ValidationResult(
                    entryCount: lineEntries.count,
                    isValid: false,
                    firstInvalidEntryIndex: entry.entryIndex,
                    firstInvalidReason: .unexpectedEntryIndex
                )
            }
            if entry.parentEntryHashHex != parentHashHex {
                return ValidationResult(
                    entryCount: lineEntries.count,
                    isValid: false,
                    firstInvalidEntryIndex: entry.entryIndex,
                    firstInvalidReason: .parentHashMismatch
                )
            }
            // Re-hash the entry to derive the next parent.
            let derived: String
            do {
                derived = try hasher.hash(entry)
            } catch {
                return ValidationResult(
                    entryCount: lineEntries.count,
                    isValid: false,
                    firstInvalidEntryIndex: entry.entryIndex,
                    firstInvalidReason: .decodeFailure
                )
            }
            parentHashHex = derived
            lineEntries.append(entry)
            expectedIndex += 1
        }

        // If the caller pinned an expected terminal head hash, verify
        // it matches the walked head. This catches tampering of the
        // last entry (which a parent-chain walk alone cannot detect).
        if let expected = expectedHeadHashHex, expected != parentHashHex {
            return ValidationResult(
                entryCount: lineEntries.count,
                isValid: false,
                firstInvalidEntryIndex: max(lineEntries.count - 1, 0),
                firstInvalidReason: .headHashMismatch,
                headHashHex: parentHashHex
            )
        }

        return ValidationResult(
            entryCount: lineEntries.count,
            isValid: true,
            headHashHex: parentHashHex == sessionManifestHashHex && lineEntries.isEmpty
                ? sessionManifestHashHex
                : parentHashHex
        )
    }

    /// Compute the manifest hash that an empty chain's first entry will
    /// list as its parent. The session-start writer pins this value in
    /// the `.head` file alongside the chain.
    public func hashSessionManifest(_ manifest: ComputerUseSessionManifest) throws -> String {
        try hasher.hash(manifest)
    }
}
