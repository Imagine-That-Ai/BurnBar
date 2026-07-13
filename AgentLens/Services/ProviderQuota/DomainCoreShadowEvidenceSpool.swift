import Foundation
import OpenBurnBarCore

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

struct DomainCoreShadowSampleV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let allowedOperations = Set([
        "claude_quota",
        "codex_quota",
        "cursor_quota",
        "anthropic_quota"
    ])

    let schemaVersion: Int
    let sampleId: String
    let domain: String
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case sampleId
        case domain
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

final class DomainCoreShadowEvidenceSpool: @unchecked Sendable {
    struct ReadyBatch: Sendable {
        let token: String
        let samples: [DomainCoreShadowSampleV1]
    }

    private let directory: URL
    private let activeURL: URL
    private let maxFileBytes: Int
    private let maxReadyFiles: Int
    private let maxSamplesPerFile: Int
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

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
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func append(_ sample: DomainCoreShadowSampleV1) throws {
        var line = try encoder.encode(sample)
        line.append(0x0A)
        guard line.count <= maxFileBytes else { throw DomainCoreShadowEvidenceError.oversizedSample }

        lock.lock()
        defer { lock.unlock() }
        if activeSizeLocked() + line.count > maxFileBytes || activeSampleCountLocked() >= maxSamplesPerFile {
            try sealActiveLocked()
        }
        if !FileManager.default.fileExists(atPath: activeURL.path) {
            FileManager.default.createFile(atPath: activeURL.path, contents: nil)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeURL.path)
        }
        let handle = try FileHandle(forWritingTo: activeURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    func nextBatch(sealActive: Bool = true) throws -> ReadyBatch? {
        lock.lock()
        defer { lock.unlock() }
        if sealActive {
            try sealActiveLocked()
        }
        guard let url = readyFilesLocked().first else { return nil }
        let data = try Data(contentsOf: url)
        let samples = try data.split(separator: 0x0A).map { line -> DomainCoreShadowSampleV1 in
            guard !line.isEmpty else { throw DomainCoreShadowEvidenceError.invalidSample }
            return try decoder.decode(DomainCoreShadowSampleV1.self, from: Data(line))
        }
        guard !samples.isEmpty, samples.count <= maxSamplesPerFile else {
            throw DomainCoreShadowEvidenceError.invalidSample
        }
        return ReadyBatch(token: url.lastPathComponent, samples: samples)
    }

    func acknowledge(_ token: String) throws {
        guard token.hasPrefix("ready-"), token.hasSuffix(".jsonl"), !token.contains("/") else {
            throw DomainCoreShadowEvidenceError.invalidSample
        }
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent(token, isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func pendingSampleCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let urls = readyFilesLocked() + (FileManager.default.fileExists(atPath: activeURL.path) ? [activeURL] : [])
        return try urls.reduce(into: 0) { count, url in
            count += try Data(contentsOf: url).split(separator: 0x0A).count
        }
    }

    private func sealActiveLocked() throws {
        guard activeSizeLocked() > 0 else { return }
        var ready = readyFilesLocked()
        while ready.count >= maxReadyFiles, let oldest = ready.first {
            try FileManager.default.removeItem(at: oldest)
            ready.removeFirst()
        }
        let millis = UInt64(Date().timeIntervalSince1970 * 1_000)
        let token = "ready-\(String(format: "%013llu", millis))-\(UUID().uuidString.lowercased()).jsonl"
        try FileManager.default.moveItem(
            at: activeURL,
            to: directory.appendingPathComponent(token, isDirectory: false)
        )
    }

    private func readyFilesLocked() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("ready-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func activeSizeLocked() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: activeURL.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func activeSampleCountLocked() -> Int {
        guard let data = try? Data(contentsOf: activeURL) else { return 0 }
        return data.split(separator: 0x0A).count
    }
}

protocol DomainCoreShadowSampleSubmitting: Sendable {
    func submit(_ samples: [DomainCoreShadowSampleV1]) async throws
}

actor DomainCoreShadowEvidenceUploadCoordinator {
    private let spool: DomainCoreShadowEvidenceSpool
    private let submitter: any DomainCoreShadowSampleSubmitting
    private var flushing = false
    private var scheduledFlush: Task<Void, Never>?
    private let debounceNanoseconds: UInt64

    init(
        spool: DomainCoreShadowEvidenceSpool,
        submitter: any DomainCoreShadowSampleSubmitting,
        debounceNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.spool = spool
        self.submitter = submitter
        self.debounceNanoseconds = debounceNanoseconds
    }

    func scheduleFlush() {
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { [debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
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
        defer {
            flushing = false
            if ((try? spool.pendingSampleCount()) ?? 0) > 0 {
                scheduleFlush()
            }
        }
        do {
            var sealActive = true
            while let batch = try spool.nextBatch(sealActive: sealActive) {
                sealActive = false
                try await submitter.submit(batch.samples)
                try spool.acknowledge(batch.token)
            }
        } catch {
            AppLogger.shared.error("domain_core_shadow_upload", metadata: ["status": "retry_pending"])
        }
    }
}

#if canImport(FirebaseAuth) && canImport(FirebaseCore) && canImport(FirebaseFunctions)
final class FirebaseDomainCoreShadowSampleSubmitter: DomainCoreShadowSampleSubmitting, @unchecked Sendable {
    func submit(_ samples: [DomainCoreShadowSampleV1]) async throws {
        guard FirebaseApp.app() != nil, Auth.auth().currentUser != nil else {
            throw DomainCoreShadowEvidenceError.signedOut
        }
        let dictionaries = try samples.map { sample -> [String: Any] in
            let data = try JSONEncoder().encode(sample)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DomainCoreShadowEvidenceError.invalidSample
            }
            return value
        }
        let result = try await Functions.functions(region: "us-central1")
            .httpsCallable("submitDomainCoreShadowSamples")
            .call(["samples": dictionaries])
        guard let response = result.data as? [String: Any],
              let accepted = response["accepted"] as? NSNumber,
              let duplicates = response["duplicates"] as? NSNumber,
              accepted.intValue + duplicates.intValue == samples.count else {
            throw DomainCoreShadowEvidenceError.invalidCallableResponse
        }
    }
}
#endif

final class MacDomainCoreShadowEvidenceRecorder: @unchecked Sendable {
    private let channel: String?
    private let spool: DomainCoreShadowEvidenceSpool?
    private let coordinator: DomainCoreShadowEvidenceUploadCoordinator?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configured = environment["OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "OpenBurnBarDomainCoreRolloutChannel") as? String
        self.channel = configured == "internal" || configured == "beta" ? configured : nil
        let directory = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))?.appendingPathComponent("OpenBurnBar/DomainCoreShadow", isDirectory: true)
        self.spool = directory.flatMap { try? DomainCoreShadowEvidenceSpool(directory: $0) }
        #if canImport(FirebaseAuth) && canImport(FirebaseCore) && canImport(FirebaseFunctions)
        self.coordinator = self.spool.map {
            DomainCoreShadowEvidenceUploadCoordinator(
                spool: $0,
                submitter: FirebaseDomainCoreShadowSampleSubmitter()
            )
        }
        #else
        self.coordinator = nil
        #endif
        if let coordinator {
            Task { await coordinator.flush() }
        }
    }

    func record(_ comparison: DomainCoreQuotaShadowComparison) {
        guard let channel, let spool,
              let sample = DomainCoreShadowSampleV1(comparison: comparison, channel: channel) else {
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
