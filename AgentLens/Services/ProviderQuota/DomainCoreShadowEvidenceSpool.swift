import Foundation
import OpenBurnBarKernel
import OpenBurnBarQuota
import os

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

struct DomainCoreShadowSampleV2: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    static let allowedOperations = Set([
        "claude_quota",
        "codex_quota",
        "cursor_quota",
        "anthropic_quota"
    ])
    static let requiredCoverage: [String: [String: Set<String>]] = [
        "quota": [
            "claude": ["apple"], "codex": ["apple"],
            "cursor": ["apple"], "anthropic": ["apple"]
        ],
        "cloudvault": [
            "foundation": ["apple"], "aes": ["apple"], "recovery": ["apple"],
            "escrow": ["apple"], "document-rewrap": ["apple"], "search": ["apple"]
        ],
        "hermes": [
            "aad": ["apple"], "payload-keywrap": ["apple"],
            "hpke-info": ["apple"], "ratchet": ["apple"]
        ],
        "pricing": ["token-cost": ["apple"]]
    ]

    let schemaVersion: Int
    let sampleId: String
    let domain: String
    let slice: String
    let consumer: String
    let channel: String
    let operation: String
    let coreVersion: String
    let observedAt: String
    let outcome: String
    let mismatchCategory: String?
    let legacyMicros: UInt64
    let rustMicros: UInt64

    init?(comparison: DomainCoreQuotaShadowComparison, channel: String) {
        guard channel == "internal" || channel == "beta",
              Self.allowedOperations.contains(comparison.operation),
              (comparison.outcome == .match) == (comparison.mismatchCategory == nil),
              comparison.legacyMicros <= 600_000_000,
              comparison.rustMicros <= 600_000_000 else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.schemaVersion = Self.schemaVersion
        self.sampleId = UUID().uuidString.lowercased()
        self.domain = "quota"
        self.slice = comparison.operation.replacingOccurrences(of: "_quota", with: "")
        self.consumer = "apple"
        self.channel = channel
        self.operation = comparison.operation
        self.coreVersion = comparison.coreVersion
        self.observedAt = formatter.string(from: comparison.observedAt)
        self.outcome = comparison.outcome.rawValue
        self.mismatchCategory = comparison.mismatchCategory?.rawValue
        self.legacyMicros = comparison.legacyMicros
        self.rustMicros = comparison.rustMicros
    }

    init?(comparison: DomainCoreShadowComparison, channel: String) {
        guard channel == "internal" || channel == "beta",
              Self.requiredCoverage[comparison.domain]?[comparison.slice]?.contains("apple") == true,
              !comparison.operation.isEmpty,
              (comparison.outcome == "match") == (comparison.mismatchCategory == nil),
              comparison.legacyMicros <= 600_000_000,
              comparison.rustMicros <= 600_000_000 else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.schemaVersion = Self.schemaVersion
        self.sampleId = UUID().uuidString.lowercased()
        self.domain = comparison.domain
        self.slice = comparison.slice
        self.consumer = "apple"
        self.channel = channel
        self.operation = comparison.operation
        self.coreVersion = comparison.coreVersion
        self.observedAt = formatter.string(from: Date())
        self.outcome = comparison.outcome
        self.mismatchCategory = comparison.mismatchCategory
        self.legacyMicros = comparison.legacyMicros
        self.rustMicros = comparison.rustMicros
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case sampleId
        case domain
        case slice
        case consumer
        case channel
        case operation
        case coreVersion
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
        try container.encode(coreVersion, forKey: .coreVersion)
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
}

final class DomainCoreShadowEvidenceSpool: Sendable {
    struct ReadyBatch: Sendable {
        let token: String
        let samples: [DomainCoreShadowSampleV2]
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

    func append(_ sample: DomainCoreShadowSampleV2) throws {
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

    func nextBatch(sealActive: Bool = true, matchingChannel: String? = nil) throws -> ReadyBatch? {
        try fileAccess.withLockUnchecked { _ in
            if sealActive {
                try sealActiveLocked()
            }
            while let url = try readyFilesLocked().first {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                let samples = try data.split(separator: 0x0A).map { line -> DomainCoreShadowSampleV2 in
                    guard !line.isEmpty else { throw DomainCoreShadowEvidenceError.invalidSample }
                    return try decoder.decode(DomainCoreShadowSampleV2.self, from: Data(line))
                }
                guard !samples.isEmpty, samples.count <= maxSamplesPerFile else {
                    throw DomainCoreShadowEvidenceError.invalidSample
                }
                guard let matchingChannel else {
                    return ReadyBatch(token: url.lastPathComponent, samples: samples)
                }
                let matchingSamples = samples.filter { $0.channel == matchingChannel }
                if matchingSamples.isEmpty {
                    try FileManager.default.removeItem(at: url)
                    continue
                }
                return ReadyBatch(token: url.lastPathComponent, samples: matchingSamples)
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
        return try urls
            .filter { $0.lastPathComponent.hasPrefix("ready-") && $0.pathExtension == "jsonl" }
            .map { url -> (ordinal: UInt64, url: URL) in
                guard let ordinal = Self.readyOrdinal(from: url.lastPathComponent) else {
                    throw DomainCoreShadowEvidenceError.invalidSample
                }
                return (ordinal, url)
            }
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
    func submit(_ samples: [DomainCoreShadowSampleV2]) async throws
}

actor DomainCoreShadowEvidenceUploadCoordinator {
    private let spool: DomainCoreShadowEvidenceSpool
    private let submitter: any DomainCoreShadowSampleSubmitting
    private let activeChannel: String
    private var flushing = false
    private var scheduledFlush: Task<Void, Never>?
    private let debounceNanoseconds: UInt64

    init(
        spool: DomainCoreShadowEvidenceSpool,
        submitter: any DomainCoreShadowSampleSubmitting,
        activeChannel: String,
        debounceNanoseconds: UInt64 = 5_000_000_000
    ) {
        precondition(activeChannel == "internal" || activeChannel == "beta")
        self.spool = spool
        self.submitter = submitter
        self.activeChannel = activeChannel
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
            while let batch = try spool.nextBatch(sealActive: sealActive, matchingChannel: activeChannel) {
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
    private struct SubmitResponse: Decodable {
        let accepted: Int
        let duplicates: Int
    }

    func submit(_ samples: [DomainCoreShadowSampleV2]) async throws {
        guard FirebaseApp.app() != nil, Auth.auth().currentUser != nil else {
            throw DomainCoreShadowEvidenceError.signedOut
        }
        let encodedSamples = try JSONEncoder().encode(samples)
        let sampleObjects = try JSONSerialization.jsonObject(with: encodedSamples)
        let result = try await Functions.functions(region: "us-central1")
            .httpsCallable("submitDomainCoreShadowSamples")
            .call(["samples": sampleObjects])
        let responseData = try JSONSerialization.data(withJSONObject: result.data)
        let response = try JSONDecoder().decode(SubmitResponse.self, from: responseData)
        guard response.accepted + response.duplicates == samples.count else {
            throw DomainCoreShadowEvidenceError.invalidCallableResponse
        }
    }
}
#endif

final class MacDomainCoreShadowEvidenceRecorder: Sendable {
    private let channel: String?
    private let spool: DomainCoreShadowEvidenceSpool?
    private let coordinator: DomainCoreShadowEvidenceUploadCoordinator?

    init(
        profile: DomainCoreBuildProfile = DomainCoreBuildProfileResolver.current(),
        directory: URL? = nil,
        submitter: (any DomainCoreShadowSampleSubmitting)? = nil,
        debounceNanoseconds: UInt64 = 5_000_000_000
    ) {
        let resolvedChannel = profile.isValid && profile.evidenceEnabled ? profile.rolloutChannel : nil
        self.channel = resolvedChannel
        let resolvedSpool: DomainCoreShadowEvidenceSpool?
        do {
            let resolvedDirectory: URL
            if let directory {
                resolvedDirectory = directory
            } else {
                resolvedDirectory = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("OpenBurnBar/DomainCoreShadow", isDirectory: true)
            }
            resolvedSpool = try DomainCoreShadowEvidenceSpool(directory: resolvedDirectory)
        } catch {
            AppLogger.shared.error("domain_core_shadow_spool", metadata: ["status": "initialization_failed"])
            resolvedSpool = nil
        }
        self.spool = resolvedSpool
        if resolvedChannel == nil {
            do {
                try self.spool?.discardAll()
            } catch {
                AppLogger.shared.error("domain_core_shadow_spool", metadata: ["status": "disabled_profile_cleanup_failed"])
            }
        }
        if let resolvedChannel, let spool = resolvedSpool, let submitter {
            self.coordinator = DomainCoreShadowEvidenceUploadCoordinator(
                spool: spool,
                submitter: submitter,
                activeChannel: resolvedChannel,
                debounceNanoseconds: debounceNanoseconds
            )
        } else {
            #if canImport(FirebaseAuth) && canImport(FirebaseCore) && canImport(FirebaseFunctions)
                self.coordinator = resolvedChannel.flatMap { activeChannel in resolvedSpool.map {
                    DomainCoreShadowEvidenceUploadCoordinator(
                        spool: $0,
                        submitter: FirebaseDomainCoreShadowSampleSubmitter(),
                        activeChannel: activeChannel,
                        debounceNanoseconds: debounceNanoseconds
                    )
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
        guard let channel, let spool,
              let sample = DomainCoreShadowSampleV2(comparison: comparison, channel: channel) else {
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
        guard let channel, let spool,
              let sample = DomainCoreShadowSampleV2(comparison: comparison, channel: channel) else {
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
}
