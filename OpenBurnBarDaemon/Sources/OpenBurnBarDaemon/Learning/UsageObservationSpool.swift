import Foundation
import OpenBurnBarKernel

public enum UsageObservationSpoolError: Error, Equatable {
    case malformedStore
    case storeTooLarge
    case unsafePath
    case insecurePermissions(String)
    case invalidObservation(String)
}

/// Bounded daemon-side spool for Safari Ask usage observations.
///
/// This actor holds observation state ONLY — the first of the four learning
/// states (`LearningCoordinator`'s observation → reviewed proposal → user
/// approval → activated persistence). Nothing in the spool promotes, reviews,
/// or activates anything; a later Stage-0 gate drains entries via the
/// two-phase `list`/`ack` pair so an app crash mid-drain loses nothing.
///
/// Appends respect an explicit `enabled` flag (default false, toggled through
/// `popup.setUsageMemory`); a disabled spool drops silently and only counts
/// the drop, which is what lets the whole pipeline ship dark.
public actor UsageObservationSpool {
    public struct Configuration: Sendable, Equatable {
        public var maximumStoreBytes: Int
        public var maximumEntryCount: Int

        public init(
            maximumStoreBytes: Int = 2 * 1024 * 1024,
            maximumEntryCount: Int = 512
        ) {
            self.maximumStoreBytes = max(64 * 1024, maximumStoreBytes)
            self.maximumEntryCount = max(1, maximumEntryCount)
        }
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var enabled: Bool
        var droppedCount: Int
        var entries: [BurnBarSafariUsageObservation]
        var updatedAt: Date
    }

    private static let schemaVersion = 1
    private static let maximumIdentifierBytes = 256
    private static let maximumSourceURLBytes = 2_048
    private static let maximumSourceTitleBytes = 512
    private static let minimumPromptBytes = 8
    private static let maximumPromptBytes = 4 * 1024
    private static let maximumAnswerPreviewBytes = 512
    private static let futureClockSkew: TimeInterval = 5 * 60

    private let stateURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let configuration: Configuration

    private var loaded = false
    private var state = Envelope(
        schemaVersion: schemaVersion,
        enabled: false,
        droppedCount: 0,
        entries: [],
        updatedAt: .distantPast
    )

    public init(
        stateURL: URL,
        fileManager: FileManager = .default,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.stateURL = stateURL.standardizedFileURL
        self.fileManager = fileManager
        self.configuration = configuration
        self.now = now
    }

    // MARK: - Spool operations

    public func setEnabled(_ enabled: Bool) throws -> Bool {
        try loadIfNeeded()
        state.enabled = enabled
        state.updatedAt = now()
        try persist()
        return state.enabled
    }

    public func isEnabled() throws -> Bool {
        try loadIfNeeded()
        return state.enabled
    }

    @discardableResult
    public func append(
        _ observation: BurnBarSafariUsageObservation
    ) throws -> (stored: Bool, droppedCount: Int) {
        try loadIfNeeded()
        try validate(observation)
        guard state.enabled else {
            state.droppedCount = saturatedIncrement(state.droppedCount)
            state.updatedAt = now()
            try persist()
            return (stored: false, droppedCount: state.droppedCount)
        }
        if state.entries.contains(where: {
            $0.observationId == observation.observationId
        }) {
            return (stored: true, droppedCount: state.droppedCount)
        }
        state.entries.append(observation)
        try enforceCapacityAndPersist()
        let stored = state.entries.contains {
            $0.observationId == observation.observationId
        }
        return (stored: stored, droppedCount: state.droppedCount)
    }

    /// Oldest first — the drain order. Listing never removes entries; the
    /// drain acknowledges exact identifiers afterwards (`ack`) so a crash
    /// between the two phases loses nothing.
    public func list(
        limit: Int
    ) throws -> (observations: [BurnBarSafariUsageObservation], droppedCount: Int) {
        try loadIfNeeded()
        let bounded = max(1, min(limit, configuration.maximumEntryCount))
        return (
            observations: Array(state.entries.prefix(bounded)),
            droppedCount: state.droppedCount
        )
    }

    public func ack(
        ids: [String]
    ) throws -> (removedCount: Int, remainingCount: Int) {
        try loadIfNeeded()
        let acked = Set(ids)
        let before = state.entries.count
        state.entries.removeAll { acked.contains($0.observationId) }
        let removed = before - state.entries.count
        if removed > 0 {
            state.updatedAt = now()
            try persist()
        }
        return (removedCount: removed, remainingCount: state.entries.count)
    }

    /// Learning-profile-delete path: the usage spool dies with the profile.
    /// Clears every entry, resets the drop counter, and disables the spool so
    /// nothing can accumulate again without a fresh explicit enable.
    public func deleteAll() throws {
        try loadIfNeeded()
        state = Envelope(
            schemaVersion: Self.schemaVersion,
            enabled: false,
            droppedCount: 0,
            entries: [],
            updatedAt: now()
        )
        try persist()
    }

    // MARK: - Validation

    private func validate(
        _ observation: BurnBarSafariUsageObservation
    ) throws {
        guard Self.isBoundedControlFree(
            observation.observationId,
            minimumBytes: 1,
            maximumBytes: Self.maximumIdentifierBytes
        ) else {
            throw UsageObservationSpoolError.invalidObservation(
                "observation identifier is empty, oversized, or contains control characters"
            )
        }
        guard let source = URL(string: observation.sourceURL),
              let scheme = source.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              source.host?.isEmpty == false,
              source.user == nil,
              source.password == nil,
              observation.sourceURL.utf8.count <= Self.maximumSourceURLBytes else {
            throw UsageObservationSpoolError.invalidObservation(
                "source URL is not a bounded credential-free web URL"
            )
        }
        guard observation.sourceTitle.utf8.count <= Self.maximumSourceTitleBytes else {
            throw UsageObservationSpoolError.invalidObservation(
                "source title is too large"
            )
        }
        let prompt = observation.prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard prompt.utf8.count >= Self.minimumPromptBytes,
              prompt.utf8.count <= Self.maximumPromptBytes else {
            throw UsageObservationSpoolError.invalidObservation(
                "prompt is outside the 8 B – 4 KiB usage-observation bounds"
            )
        }
        guard observation.answerSha256.utf8.count == 64,
              observation.answerSha256.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw UsageObservationSpoolError.invalidObservation(
                "answer digest is not a lowercase hex SHA-256"
            )
        }
        guard observation.answerPreview.utf8.count
                <= Self.maximumAnswerPreviewBytes else {
            throw UsageObservationSpoolError.invalidObservation(
                "answer preview is too large"
            )
        }
        guard observation.observedAt
                <= now().addingTimeInterval(Self.futureClockSkew) else {
            throw UsageObservationSpoolError.invalidObservation(
                "observation timestamp is in the future"
            )
        }
    }

    private func validate(_ envelope: Envelope) throws {
        guard envelope.schemaVersion == Self.schemaVersion,
              envelope.droppedCount >= 0,
              envelope.entries.count <= configuration.maximumEntryCount,
              Set(envelope.entries.map(\.observationId)).count
                == envelope.entries.count,
              envelope.updatedAt
                <= now().addingTimeInterval(Self.futureClockSkew) else {
            throw UsageObservationSpoolError.malformedStore
        }
    }

    private static func isBoundedControlFree(
        _ value: String,
        minimumBytes: Int,
        maximumBytes: Int
    ) -> Bool {
        let bytes = value.utf8.count
        return bytes >= minimumBytes
            && bytes <= maximumBytes
            && !value.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
            )
    }

    private func saturatedIncrement(_ value: Int) -> Int {
        value == Int.max ? value : value + 1
    }

    // MARK: - Persistence

    private func enforceCapacityAndPersist() throws {
        while state.entries.count > configuration.maximumEntryCount {
            state.entries.removeFirst()
            state.droppedCount = saturatedIncrement(state.droppedCount)
        }
        state.updatedAt = now()
        var data = try encoded(state)
        while data.count > configuration.maximumStoreBytes,
              state.entries.isEmpty == false {
            state.entries.removeFirst()
            state.droppedCount = saturatedIncrement(state.droppedCount)
            data = try encoded(state)
        }
        guard data.count <= configuration.maximumStoreBytes else {
            throw UsageObservationSpoolError.storeTooLarge
        }
        try persist(encoded: data)
    }

    private func loadIfNeeded() throws {
        guard loaded == false else { return }
        guard fileManager.fileExists(atPath: stateURL.path) else {
            state.updatedAt = now()
            loaded = true
            return
        }
        let values = try stateURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw UsageObservationSpoolError.malformedStore
        }
        guard let size = values.fileSize,
              size > 0,
              size <= configuration.maximumStoreBytes else {
            throw UsageObservationSpoolError.storeTooLarge
        }
        try requireOwnerOnlyPermissions(stateURL, directory: false)
        try requireOwnerOnlyPermissions(
            stateURL.deletingLastPathComponent(),
            directory: true
        )
        let data = try Data(contentsOf: stateURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: Envelope
        do {
            decoded = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw UsageObservationSpoolError.malformedStore
        }
        try validate(decoded)
        for entry in decoded.entries {
            try validate(entry)
        }
        state = decoded
        loaded = true
    }

    private func persist() throws {
        try persist(encoded: encoded(state))
    }

    private func encoded(_ envelope: Envelope) throws -> Data {
        try validate(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    private func persist(encoded data: Data) throws {
        guard data.count <= configuration.maximumStoreBytes else {
            throw UsageObservationSpoolError.storeTooLarge
        }
        let directory = stateURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: stateURL.path) {
            try requireOwnerOnlyPermissions(directory, directory: true)
            let values = try stateURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw UsageObservationSpoolError.unsafePath
            }
            try requireOwnerOnlyPermissions(stateURL, directory: false)
        }
        try ensureSecureDirectory(directory)
        try data.write(to: stateURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: stateURL.path
        )
        try requireOwnerOnlyPermissions(stateURL, directory: false)
    }

    private func ensureSecureDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw UsageObservationSpoolError.unsafePath
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
    }

    private func requireOwnerOnlyPermissions(
        _ url: URL,
        directory: Bool
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw UsageObservationSpoolError.insecurePermissions(url.path)
        }
        let mode = permissions.intValue
        let allowed = directory ? 0o700 : 0o600
        guard mode & 0o077 == 0, mode & allowed != 0 else {
            throw UsageObservationSpoolError.insecurePermissions(url.path)
        }
    }
}
