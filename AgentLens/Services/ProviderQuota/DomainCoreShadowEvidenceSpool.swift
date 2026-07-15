import Foundation
import OpenBurnBarKernel
import OpenBurnBarQuota
import os

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

#if canImport(FirebaseAuth) && canImport(FirebaseCore) && canImport(FirebaseFunctions)
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFunctions
#endif

enum DomainCoreShadowEvidenceError: Error {
    case invalidChannel
    case invalidSample
    case oversizedSample
    case invalidCallableResponse
    case signedOut
}

struct DomainCoreEvidenceLoadedIdentity: Codable, Equatable, Sendable {
    let coreVersion: String
    let abiVersion: UInt32
    let sourceSha256: String

    static func current() -> Self? {
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard let abiVersion = try? SafeQuotaFFI.domainCoreAbiVersion(),
              let coreVersion = try? SafeQuotaFFI.domainCoreVersion() else { return nil }
        return Self(
            coreVersion: coreVersion,
            abiVersion: abiVersion,
            sourceSha256: OpenBurnBarDomainCoreFFI.domainCoreSourceFingerprint()
        )
        #else
        return nil
        #endif
    }
}

struct DomainCoreShadowSampleV3: Codable, Equatable, Sendable {
    static let schemaVersion = 3
    static let storedKeys = Set(CodingKeys.allCases.map(\.stringValue))
    static let allowedOperations: [String: [String: Set<String>]] = [
        "quota": [
            "claude": ["claude_quota"], "codex": ["codex_quota"],
            "cursor": ["cursor_quota"], "anthropic": ["anthropic_quota"]
        ],
        "cloudvault": [
            "foundation": [
                "aad_v1", "aad_v2", "resolve_aad", "sha256", "sha256_hex", "vault_key_id",
                "blob_integrity", "session_body", "session_chunk", "project_memory_content",
                "blob_integrity_hash", "session_body_hash", "session_chunk_hash", "project_memory_content_hash",
                "keyed_hash_blob_integrity", "expected_session_body_hash", "expected_session_body_hash_v0",
                "expected_session_body_hash_v1", "expected_session_body_hash_v2", "base64_encode", "base64_decode",
                "base64_decode_strict", "p256_validate_public_key", "initialize", "cloudvault_aad_v1",
                "cloudvault_aad_v2", "cloudvault_resolve_aad", "cloudvault_sha256", "cloudvault_key_id",
                "cloudvault_keyed_hash", "cloudvault_base64_encode", "cloudvault_base64_decode",
                "cloudvault_validate_p256_public_key"
            ],
            "aes": [
                "aes_gcm_seal_detached", "aes_gcm_seal_combined", "aes_gcm_open_detached",
                "aes_gcm_open_text_detached", "aes_gcm_open_combined", "aes_seal_detached",
                "aes_seal_combined", "aes_open_detached", "aes_open_text", "aes_open_combined",
                "cloudvault_aes_seal_detached", "cloudvault_aes_seal_combined",
                "cloudvault_aes_open_detached", "cloudvault_aes_open_text", "cloudvault_aes_open_combined"
            ],
            "recovery": [
                "recovery_normalize", "recovery_wrapping_key", "recovery_verification_hash",
                "recovery_wrap_vault_key", "recovery_open_vault_key", "cloudvault_recovery_wrapping_key",
                "cloudvault_recovery_verification_hash", "cloudvault_recovery_wrap_vault_key",
                "cloudvault_recovery_open_vault_key"
            ],
            "escrow": [
                "escrow_wrapping_key", "escrow_assemble_wire", "escrow_split_wire", "escrow_seal", "escrow_open",
                "cloudvault_escrow_split_wire", "cloudvault_escrow_seal", "cloudvault_escrow_open"
            ],
            "document-rewrap": ["document_rewrap"],
            "search": ["token", "index", "query", "semantic"]
        ],
        "hermes": [
            "aad": ["aad"],
            "payload-keywrap": ["key_wrap_info_v1", "key_wrap_info_v2", "seal", "open", "safety_code", "hkdf"],
            "hpke-info": ["hpke_v3_info"],
            "ratchet": ["ratchet_aad", "ratchet_root_kdf", "ratchet_chain_kdf", "ratchet_message_kdf", "ratchet_seal", "ratchet_open"]
        ],
        "pricing": ["token-cost": ["calculate_token_cost"]]
    ]

    let schemaVersion: Int
    let sampleId: String
    let domain: String
    let slice: String
    let consumer: String
    let channel: String
    let operation: String
    let candidateCommit: String
    let expectedCoreVersion: String
    let expectedCoreAbiVersion: UInt32
    let expectedCoreSourceSha256: String
    let loadedCoreVersion: String?
    let loadedCoreAbiVersion: UInt32?
    let loadedCoreSourceSha256: String?
    let observedAt: String
    let outcome: String
    let mismatchCategory: String?
    let legacyMicros: UInt64
    let rustMicros: UInt64

    init?(
        comparison: DomainCoreQuotaShadowComparison,
        channel: String,
        candidate: DomainCoreCandidateIdentity,
        loadedIdentity: DomainCoreEvidenceLoadedIdentity?
    ) {
        let slice = comparison.operation.replacingOccurrences(of: "_quota", with: "")
        guard channel == "internal" || channel == "beta",
              Self.allowedOperations["quota"]?[slice]?.contains(comparison.operation) == true,
              comparison.legacyMicros <= 600_000_000,
              comparison.rustMicros <= 600_000_000 else {
            return nil
        }
        self.init(
            domain: "quota", slice: slice, operation: comparison.operation, channel: channel,
            candidate: candidate, loadedIdentity: loadedIdentity,
            observedAt: comparison.observedAt, outcome: comparison.outcome.rawValue,
            mismatchCategory: comparison.mismatchCategory?.rawValue,
            legacyMicros: comparison.legacyMicros, rustMicros: comparison.rustMicros
        )
    }

    init?(
        comparison: DomainCoreShadowComparison,
        channel: String,
        candidate: DomainCoreCandidateIdentity,
        loadedIdentity: DomainCoreEvidenceLoadedIdentity?
    ) {
        guard channel == "internal" || channel == "beta",
              Self.allowedOperations[comparison.domain]?[comparison.slice]?.contains(comparison.operation) == true,
              comparison.legacyMicros <= 600_000_000,
              comparison.rustMicros <= 600_000_000 else {
            return nil
        }
        self.init(
            domain: comparison.domain, slice: comparison.slice, operation: comparison.operation, channel: channel,
            candidate: candidate, loadedIdentity: loadedIdentity,
            observedAt: comparison.observedAt, outcome: comparison.outcome,
            mismatchCategory: comparison.mismatchCategory,
            legacyMicros: comparison.legacyMicros, rustMicros: comparison.rustMicros
        )
    }

    private init?(
        domain: String,
        slice: String,
        operation: String,
        channel: String,
        candidate: DomainCoreCandidateIdentity,
        loadedIdentity: DomainCoreEvidenceLoadedIdentity?,
        observedAt: Date,
        outcome proposedOutcome: String,
        mismatchCategory proposedMismatchCategory: String?,
        legacyMicros: UInt64,
        rustMicros: UInt64
    ) {
        let loadedMismatch = loadedIdentity.map {
            $0.coreVersion != candidate.coreVersion || $0.abiVersion != candidate.abiVersion || $0.sourceSha256 != candidate.sourceSha256
        } ?? false
        let outcome = loadedIdentity == nil || loadedMismatch ? "mismatch" : proposedOutcome
        let mismatchCategory = if loadedIdentity == nil {
            "native_unavailable"
        } else if loadedMismatch {
            "loaded_identity_mismatch"
        } else if proposedMismatchCategory == "native_unavailable" {
            "native_error"
        } else {
            proposedMismatchCategory
        }
        let validCategories: Set<String> = [
            "result_mismatch", "native_unavailable", "native_error", "invalid_result", "loaded_identity_mismatch"
        ]
        guard (outcome == "match" && mismatchCategory == nil && loadedIdentity != nil)
                || (outcome == "mismatch" && mismatchCategory.map(validCategories.contains) == true),
              mismatchCategory != "native_unavailable" || loadedIdentity == nil,
              mismatchCategory == "native_unavailable" || loadedIdentity != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.schemaVersion = Self.schemaVersion
        self.sampleId = UUID().uuidString.lowercased()
        self.domain = domain
        self.slice = slice
        self.consumer = "apple"
        self.channel = channel
        self.operation = operation
        self.candidateCommit = candidate.candidateCommit
        self.expectedCoreVersion = candidate.coreVersion
        self.expectedCoreAbiVersion = candidate.abiVersion
        self.expectedCoreSourceSha256 = candidate.sourceSha256
        self.loadedCoreVersion = loadedIdentity?.coreVersion
        self.loadedCoreAbiVersion = loadedIdentity?.abiVersion
        self.loadedCoreSourceSha256 = loadedIdentity?.sourceSha256
        self.observedAt = formatter.string(from: observedAt)
        self.outcome = outcome
        self.mismatchCategory = mismatchCategory
        self.legacyMicros = legacyMicros
        self.rustMicros = rustMicros
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case sampleId
        case domain
        case slice
        case consumer
        case channel
        case operation
        case candidateCommit
        case expectedCoreVersion
        case expectedCoreAbiVersion
        case expectedCoreSourceSha256
        case loadedCoreVersion
        case loadedCoreAbiVersion
        case loadedCoreSourceSha256
        case observedAt
        case outcome
        case mismatchCategory
        case legacyMicros
        case rustMicros
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sampleId, forKey: .sampleId)
        try container.encode(domain, forKey: .domain)
        try container.encode(slice, forKey: .slice)
        try container.encode(consumer, forKey: .consumer)
        try container.encode(channel, forKey: .channel)
        try container.encode(operation, forKey: .operation)
        try container.encode(candidateCommit, forKey: .candidateCommit)
        try container.encode(expectedCoreVersion, forKey: .expectedCoreVersion)
        try container.encode(expectedCoreAbiVersion, forKey: .expectedCoreAbiVersion)
        try container.encode(expectedCoreSourceSha256, forKey: .expectedCoreSourceSha256)
        try container.encodeIfPresent(loadedCoreVersion, forKey: .loadedCoreVersion)
        if loadedCoreVersion == nil { try container.encodeNil(forKey: .loadedCoreVersion) }
        try container.encodeIfPresent(loadedCoreAbiVersion, forKey: .loadedCoreAbiVersion)
        if loadedCoreAbiVersion == nil { try container.encodeNil(forKey: .loadedCoreAbiVersion) }
        try container.encodeIfPresent(loadedCoreSourceSha256, forKey: .loadedCoreSourceSha256)
        if loadedCoreSourceSha256 == nil { try container.encodeNil(forKey: .loadedCoreSourceSha256) }
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(outcome, forKey: .outcome)
        if let mismatchCategory {
            try container.encode(mismatchCategory, forKey: .mismatchCategory)
        } else {
            try container.encodeNil(forKey: .mismatchCategory)
        }
        try container.encode(legacyMicros, forKey: .legacyMicros)
        try container.encode(rustMicros, forKey: .rustMicros)
    }

    func isValidStored(
        matchingChannel: String?,
        matchingCandidate: DomainCoreCandidateIdentity?,
        now: Date
    ) -> Bool {
        guard schemaVersion == Self.schemaVersion,
              Self.matches(sampleId, pattern: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#),
              consumer == "apple",
              channel == "internal" || channel == "beta",
              Self.allowedOperations[domain]?[slice]?.contains(operation) == true,
              Self.matches(candidateCommit, pattern: #"^[0-9a-f]{40}$"#),
              Self.isCanonicalCoreVersion(expectedCoreVersion),
              expectedCoreAbiVersion > 0,
              Self.matches(expectedCoreSourceSha256, pattern: #"^[0-9a-f]{64}$"#),
              legacyMicros <= 600_000_000,
              rustMicros <= 600_000_000,
              Self.isAcceptedTimestamp(observedAt, now: now) else { return false }
        if let matchingChannel, channel != matchingChannel { return false }
        if let matchingCandidate,
           candidateCommit != matchingCandidate.candidateCommit
            || expectedCoreVersion != matchingCandidate.coreVersion
            || expectedCoreAbiVersion != matchingCandidate.abiVersion
            || expectedCoreSourceSha256 != matchingCandidate.sourceSha256 {
            return false
        }

        let loadedIsNull = loadedCoreVersion == nil
            && loadedCoreAbiVersion == nil
            && loadedCoreSourceSha256 == nil
        let loadedIsPresent = loadedCoreVersion != nil
            && loadedCoreAbiVersion != nil
            && loadedCoreSourceSha256 != nil
        guard loadedIsNull || loadedIsPresent else { return false }
        if loadedIsPresent {
            guard let loadedCoreVersion, let loadedCoreAbiVersion, let loadedCoreSourceSha256,
                  Self.isCanonicalCoreVersion(loadedCoreVersion),
                  loadedCoreAbiVersion > 0,
                  Self.matches(loadedCoreSourceSha256, pattern: #"^[0-9a-f]{64}$"#) else { return false }
        }
        let loadedMatchesExpected = loadedCoreVersion == expectedCoreVersion
            && loadedCoreAbiVersion == expectedCoreAbiVersion
            && loadedCoreSourceSha256 == expectedCoreSourceSha256
        let validCategories: Set<String> = [
            "result_mismatch", "native_unavailable", "native_error", "invalid_result", "loaded_identity_mismatch"
        ]
        guard (outcome == "match" && mismatchCategory == nil)
                || (outcome == "mismatch" && mismatchCategory.map(validCategories.contains) == true) else {
            return false
        }
        let requiresExpectedIdentity = outcome == "match"
            || mismatchCategory == "result_mismatch"
            || mismatchCategory == "invalid_result"
            || mismatchCategory == "native_error"
        if requiresExpectedIdentity && !loadedMatchesExpected { return false }
        if mismatchCategory == "native_unavailable" && !loadedIsNull { return false }
        if mismatchCategory == "loaded_identity_mismatch" && (!loadedIsPresent || loadedMatchesExpected) {
            return false
        }
        return true
    }

    private static func isCanonicalCoreVersion(_ value: String) -> Bool {
        value.count <= 64 && matches(
            value,
            pattern: #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        )
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: range) else { return false }
        return match.range == range
    }

    private static func isAcceptedTimestamp(_ value: String, now: Date) -> Bool {
        guard matches(value, pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$"#) else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        guard let observedAt = formatter.date(from: value) else { return false }
        return observedAt >= now.addingTimeInterval(-31 * 24 * 60 * 60)
            && observedAt <= now.addingTimeInterval(5 * 60)
    }
}

final class DomainCoreShadowEvidenceSpool: Sendable {
    struct ReadyBatch: Sendable {
        let token: String
        let samples: [DomainCoreShadowSampleV3]
    }

    private let directory: URL
    private let activeURL: URL
    private let maxFileBytes: Int
    private let maxReadyFiles: Int
    private let maxSamplesPerFile: Int
    private let fileAccess = OSAllocatedUnfairLock(initialState: ())

    init(
        directory: URL,
        maxFileBytes: Int = 256 * 1_024,
        maxReadyFiles: Int = 8,
        maxSamplesPerFile: Int = 100
    ) throws {
        precondition(maxFileBytes > 0 && maxReadyFiles > 0 && maxSamplesPerFile > 0)
        self.directory = directory
        self.activeURL = directory.appendingPathComponent("active.jsonl", isDirectory: false)
        self.maxFileBytes = maxFileBytes
        self.maxReadyFiles = maxReadyFiles
        self.maxSamplesPerFile = maxSamplesPerFile
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func append(_ sample: DomainCoreShadowSampleV3) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(sample)
        line.append(0x0A)
        guard line.count <= maxFileBytes else { throw DomainCoreShadowEvidenceError.oversizedSample }

        try fileAccess.withLockUnchecked { _ in
            let activeSize = try activeSizeLocked()
            let activeSampleCount = try activeSampleCountLocked()
            if activeSize + line.count > maxFileBytes || activeSampleCount >= maxSamplesPerFile {
                try sealActiveLocked()
            }
            if !FileManager.default.fileExists(atPath: activeURL.path) {
                guard FileManager.default.createFile(atPath: activeURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeURL.path)
            }
            let handle = try FileHandle(forWritingTo: activeURL)
            defer {
                do {
                    try handle.close()
                } catch {
                    AppLogger.shared.error("domain_core_shadow_spool", metadata: ["status": "close_failed"])
                }
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        }
    }

    func nextBatch(
        sealActive: Bool = true,
        matchingChannel: String? = nil,
        matchingCandidate: DomainCoreCandidateIdentity? = nil,
        now: Date = Date()
    ) throws -> ReadyBatch? {
        try fileAccess.withLockUnchecked { _ in
            if sealActive {
                try sealActiveLocked()
            }
            while let url = try readyFilesLocked().first {
                // A read failure can be transient. Keep the unacknowledged file for retry;
                // only successfully-read bytes may be classified as corrupt and discarded.
                let data = try Data(contentsOf: url)
                let lines = data.split(separator: 0x0A)
                guard !lines.isEmpty, lines.count <= maxSamplesPerFile else {
                    try FileManager.default.removeItem(at: url)
                    continue
                }
                let decoder = JSONDecoder()
                let samples = lines.compactMap { line -> DomainCoreShadowSampleV3? in
                    let lineData = Data(line)
                    guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          Set(object.keys) == DomainCoreShadowSampleV3.storedKeys,
                          let sample = try? decoder.decode(DomainCoreShadowSampleV3.self, from: lineData),
                          sample.isValidStored(
                              matchingChannel: matchingChannel,
                              matchingCandidate: matchingCandidate,
                              now: now
                          ) else { return nil }
                    return sample
                }
                if samples.isEmpty {
                    try FileManager.default.removeItem(at: url)
                    continue
                }
                return ReadyBatch(token: url.lastPathComponent, samples: samples)
            }
            return nil
        }
    }

    func discardAll() throws {
        try fileAccess.withLockUnchecked { _ in
            let ready = try readyFilesLocked()
            for url in ready {
                try FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: activeURL.path) {
                try FileManager.default.removeItem(at: activeURL)
            }
        }
    }

    func acknowledge(_ token: String) throws {
        guard Self.readyOrdinal(from: token) != nil, !token.contains("/") else {
            throw DomainCoreShadowEvidenceError.invalidSample
        }
        try fileAccess.withLockUnchecked { _ in
            let url = directory.appendingPathComponent(token, isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func pendingSampleCount() throws -> Int {
        try fileAccess.withLockUnchecked { _ in
            let urls = try readyFilesLocked()
                + (FileManager.default.fileExists(atPath: activeURL.path) ? [activeURL] : [])
            return try urls.reduce(into: 0) { count, url in
                count += try Data(contentsOf: url).split(separator: 0x0A).count
            }
        }
    }

    private func sealActiveLocked() throws {
        guard try activeSizeLocked() > 0 else { return }
        var ready = try readyFilesLocked()
        while ready.count >= maxReadyFiles, let oldest = ready.first {
            try FileManager.default.removeItem(at: oldest)
            ready.removeFirst()
        }
        let ordinal: UInt64
        if let last = ready.last.flatMap({ Self.readyOrdinal(from: $0.lastPathComponent) }) {
            let increment = last.addingReportingOverflow(1)
            guard !increment.overflow else { throw DomainCoreShadowEvidenceError.invalidSample }
            ordinal = increment.partialValue
        } else {
            ordinal = 0
        }
        let token = "ready-\(String(format: "%020llu", ordinal)).jsonl"
        try FileManager.default.moveItem(
            at: activeURL,
            to: directory.appendingPathComponent(token, isDirectory: false)
        )
    }

    private func readyFilesLocked() throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var ready: [(ordinal: UInt64, url: URL)] = []
        for url in urls where url.lastPathComponent.hasPrefix("ready-") && url.pathExtension == "jsonl" {
            guard let ordinal = Self.readyOrdinal(from: url.lastPathComponent) else {
                try FileManager.default.removeItem(at: url)
                continue
            }
            ready.append((ordinal, url))
        }
        return ready
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.url)
    }

    private static func readyOrdinal(from token: String) -> UInt64? {
        let prefix = "ready-"
        let suffix = ".jsonl"
        guard token.hasPrefix(prefix), token.hasSuffix(suffix) else { return nil }
        let start = token.index(token.startIndex, offsetBy: prefix.count)
        let end = token.index(token.endIndex, offsetBy: -suffix.count)
        let digits = token[start..<end]
        guard digits.count == 20, digits.allSatisfy(\.isNumber) else { return nil }
        return UInt64(digits)
    }

    private func activeSizeLocked() throws -> Int {
        guard FileManager.default.fileExists(atPath: activeURL.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: activeURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return size.intValue
    }

    private func activeSampleCountLocked() throws -> Int {
        guard FileManager.default.fileExists(atPath: activeURL.path) else { return 0 }
        let data = try Data(contentsOf: activeURL)
        return data.split(separator: 0x0A).count
    }
}

protocol DomainCoreShadowSampleSubmitting: Sendable {
    func submit(_ samples: [DomainCoreShadowSampleV3]) async throws
}

enum DomainCoreShadowAcknowledgementValidator {
    private struct Response: Decodable {
        let accepted: Int
        let duplicates: Int
    }

    static func validate(_ object: Any, batchSize: Int) throws {
        guard batchSize >= 0 else { throw DomainCoreShadowEvidenceError.invalidCallableResponse }
        let response: Response
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DomainCoreShadowEvidenceError.invalidCallableResponse
        }
        let total = response.accepted.addingReportingOverflow(response.duplicates)
        guard response.accepted >= 0,
              response.duplicates >= 0,
              response.accepted <= batchSize,
              response.duplicates <= batchSize,
              !total.overflow,
              total.partialValue == batchSize else {
            throw DomainCoreShadowEvidenceError.invalidCallableResponse
        }
    }
}

actor DomainCoreShadowEvidenceUploadCoordinator {
    private let spool: DomainCoreShadowEvidenceSpool
    private let submitter: any DomainCoreShadowSampleSubmitting
    private let activeChannel: String
    private let activeCandidate: DomainCoreCandidateIdentity
    private var flushing = false
    private var scheduledFlush: Task<Void, Never>?
    private let debounceNanoseconds: UInt64

    init(
        spool: DomainCoreShadowEvidenceSpool,
        submitter: any DomainCoreShadowSampleSubmitting,
        activeChannel: String,
        activeCandidate: DomainCoreCandidateIdentity,
        debounceNanoseconds: UInt64 = 5_000_000_000
    ) {
        precondition(activeChannel == "internal" || activeChannel == "beta")
        self.spool = spool
        self.submitter = submitter
        self.activeChannel = activeChannel
        self.activeCandidate = activeCandidate
        self.debounceNanoseconds = debounceNanoseconds
    }

    func scheduleFlush() {
        scheduledFlush?.cancel()
        scheduledFlush = Task { [debounceNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.runScheduledFlush()
        }
    }

    private func runScheduledFlush() async {
        scheduledFlush = nil
        await flush()
    }

    func flush() async {
        guard !flushing else { return }
        scheduledFlush?.cancel()
        scheduledFlush = nil
        flushing = true
        do {
            var sealActive = true
            while let batch = try spool.nextBatch(
                sealActive: sealActive,
                matchingChannel: activeChannel,
                matchingCandidate: activeCandidate
            ) {
                sealActive = false
                try await submitter.submit(batch.samples)
                try spool.acknowledge(batch.token)
            }
        } catch {
            AppLogger.shared.error("domain_core_shadow_upload", metadata: ["status": "retry_pending"])
        }
        flushing = false
        do {
            if try spool.pendingSampleCount() > 0 {
                scheduleFlush()
            }
        } catch {
            AppLogger.shared.error("domain_core_shadow_upload", metadata: ["status": "pending_count_failed"])
        }
    }
}

#if canImport(FirebaseAuth) && canImport(FirebaseCore) && canImport(FirebaseFunctions)
final class FirebaseDomainCoreShadowSampleSubmitter: DomainCoreShadowSampleSubmitting, Sendable {
    func submit(_ samples: [DomainCoreShadowSampleV3]) async throws {
        guard FirebaseApp.app() != nil, Auth.auth().currentUser != nil else {
            throw DomainCoreShadowEvidenceError.signedOut
        }
        let encodedSamples = try JSONEncoder().encode(samples)
        let sampleObjects = try JSONSerialization.jsonObject(with: encodedSamples)
        let result = try await Functions.functions(region: "us-central1")
            .httpsCallable("submitDomainCoreShadowSamples")
            .call(["samples": sampleObjects])
        try DomainCoreShadowAcknowledgementValidator.validate(result.data, batchSize: samples.count)
    }
}
#endif

final class MacDomainCoreShadowEvidenceRecorder: Sendable {
    private let channel: String?
    private let candidate: DomainCoreCandidateIdentity?
    private let spool: DomainCoreShadowEvidenceSpool?
    private let coordinator: DomainCoreShadowEvidenceUploadCoordinator?
    private let loadedIdentity: @Sendable () -> DomainCoreEvidenceLoadedIdentity?

    init(
        profile: DomainCoreBuildProfile = DomainCoreBuildProfileResolver.current(),
        directory: URL? = nil,
        submitter: (any DomainCoreShadowSampleSubmitting)? = nil,
        debounceNanoseconds: UInt64 = 5_000_000_000,
        loadedIdentity: @escaping @Sendable () -> DomainCoreEvidenceLoadedIdentity? = DomainCoreEvidenceLoadedIdentity.current
    ) {
        let resolvedCandidate = profile.artifactAuthority == "signed" && profile.isValid && profile.evidenceEnabled
            ? profile.candidateIdentity : nil
        let resolvedChannel = resolvedCandidate == nil ? nil : profile.rolloutChannel
        self.channel = resolvedChannel
        self.candidate = resolvedCandidate
        self.loadedIdentity = loadedIdentity
        let resolvedSpool: DomainCoreShadowEvidenceSpool?
        do {
            let resolvedDirectory: URL
            if let directory {
                resolvedDirectory = directory
            } else {
                let baseDirectory = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("OpenBurnBar/DomainCoreShadow", isDirectory: true)
                resolvedDirectory = try resolvedCandidate.map {
                    try Self.prepareCandidateDirectory(base: baseDirectory, candidate: $0)
                } ?? baseDirectory
            }
            if resolvedCandidate == nil {
                try Self.cleanupEvidenceRoot(at: resolvedDirectory, preservingNamespace: nil)
                resolvedSpool = nil
            } else {
                resolvedSpool = try DomainCoreShadowEvidenceSpool(directory: resolvedDirectory)
            }
        } catch {
            AppLogger.shared.error("domain_core_shadow_spool", metadata: ["status": "initialization_failed"])
            resolvedSpool = nil
        }
        self.spool = resolvedSpool
        if let resolvedChannel, let resolvedCandidate, let spool = resolvedSpool, let submitter {
            self.coordinator = DomainCoreShadowEvidenceUploadCoordinator(
                spool: spool,
                submitter: submitter,
                activeChannel: resolvedChannel,
                activeCandidate: resolvedCandidate,
                debounceNanoseconds: debounceNanoseconds
            )
        } else {
            #if canImport(FirebaseAuth) && canImport(FirebaseCore) && canImport(FirebaseFunctions)
                self.coordinator = resolvedChannel.flatMap { activeChannel in resolvedSpool.flatMap { spool in
                    resolvedCandidate.map { candidate in
                    DomainCoreShadowEvidenceUploadCoordinator(
                        spool: spool,
                        submitter: FirebaseDomainCoreShadowSampleSubmitter(),
                        activeChannel: activeChannel,
                        activeCandidate: candidate,
                        debounceNanoseconds: debounceNanoseconds
                    )
                    }
                } }
            #else
            self.coordinator = nil
            #endif
        }
        if let coordinator {
            Task { await coordinator.flush() }
        }
        DomainCoreShadowComparisonCollector.configure { [weak self] comparison in
            self?.record(comparison)
        }
    }

    func record(_ comparison: DomainCoreQuotaShadowComparison) {
        guard let channel, let candidate, let spool,
              let sample = DomainCoreShadowSampleV3(
                  comparison: comparison,
                  channel: channel,
                  candidate: candidate,
                  loadedIdentity: loadedIdentity()
              ) else {
            return
        }
        do {
            try spool.append(sample)
            if let coordinator {
                Task { await coordinator.scheduleFlush() }
            }
        } catch {
            AppLogger.shared.error("domain_core_shadow_spool", metadata: ["status": "append_failed"])
        }
    }

    private func record(_ comparison: DomainCoreShadowComparison) {
        guard let channel, let candidate, let spool,
              let sample = DomainCoreShadowSampleV3(
                  comparison: comparison,
                  channel: channel,
                  candidate: candidate,
                  loadedIdentity: loadedIdentity()
              ) else {
            return
        }
        do {
            try spool.append(sample)
            if let coordinator {
                Task { await coordinator.scheduleFlush() }
            }
        } catch {
            AppLogger.shared.error("domain_core_shadow_spool", metadata: ["status": "append_failed"])
        }
    }

    static func candidateNamespace(_ candidate: DomainCoreCandidateIdentity) -> String {
        "v3-\(candidate.candidateCommit)-\(candidate.coreVersion)-\(candidate.abiVersion)-\(candidate.sourceSha256)"
    }

    static func prepareCandidateDirectory(base: URL, candidate: DomainCoreCandidateIdentity) throws -> URL {
        let namespace = candidateNamespace(candidate)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try cleanupEvidenceRoot(at: base, preservingNamespace: namespace)
        return base.appendingPathComponent(namespace, isDirectory: true)
    }

    private static func cleanupEvidenceRoot(at directory: URL, preservingNamespace: String?) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let name = url.lastPathComponent
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let isLegacyQueueFile = values.isRegularFile == true
                && (name == "active.jsonl" || (name.hasPrefix("ready-") && url.pathExtension == "jsonl"))
            let isStaleCandidateDirectory = values.isDirectory == true
                && ["v1-", "v2-", "v3-"].contains { name.hasPrefix($0) }
                && name != preservingNamespace
            if isLegacyQueueFile || isStaleCandidateDirectory {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
