import Foundation
import OpenBurnBarKernel

/// One contiguous stretch of a provider's local timeline during which a single
/// account was the signed-in identity on this device.
public struct ProviderAccountIdentityWindow: Codable, Equatable, Sendable {
    public var rawIdentity: String
    public var label: String
    public var scope: ProviderAccountStorageScope
    public var firstSeen: Date
    public var lastSeen: Date
}

/// Device-local journal of which account was signed in to each provider's tool
/// over time. Local usage parsed later is attributed by intersecting the
/// session interval with these windows.
///
/// Coverage semantics: an identity holds from its `firstSeen` until a
/// *different* identity is first observed for the same provider, so observation
/// gaps do not un-attribute usage.
///
/// History recorded before the first observation stays deliberately
/// unattributed. Backdating the first-seen identity over pre-existing rows
/// would silently assign every past session to whichever account happened to be
/// signed in when attribution first ran — on a multi-seat device (the case this
/// feature exists for) that is wrong often enough to mislead someone into
/// cancelling the wrong seat. Unattributed history keeps reporting under the
/// provider's existing default lane instead.
public final class ProviderAccountIdentityTimelineStore: Sendable {
    struct State: Codable, Equatable, Sendable {
        var schemaVersion: Int = 1
        var windows: [String: [ProviderAccountIdentityWindow]] = [:]
    }

    /// Journal plus the bookkeeping the persist throttle needs, held together so
    /// one `Locked` guards both.
    private struct Storage: Sendable {
        var state: State
        var lastPersistedAt: Date?
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let storage: Locked<Storage>

    /// `lastSeen` advances on every observation. A pure `lastSeen` bump is
    /// rewritten at most this often so refresh ticks do not rewrite the file
    /// continuously; anything that changes attribution is written immediately.
    private static let lastSeenPersistInterval: TimeInterval = 60

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? Self.decoder.decode(State.self, from: $0) }
        self.storage = Locked(Storage(state: loaded ?? State(), lastPersistedAt: nil))
    }

    public func observe(
        _ identity: ResolvedProviderAccountIdentity,
        provider: AgentProvider,
        at date: Date = Date()
    ) {
        storage.withLock { storage in
            var windows = storage.state.windows[provider.rawValue] ?? []
            // Anything other than advancing `lastSeen` changes how rows
            // attribute, so it is persisted immediately rather than waiting for
            // the throttle.
            let changesAttribution: Bool
            if var last = windows.last, last.rawIdentity == identity.rawIdentity {
                changesAttribution = last.label != identity.label || last.scope != identity.scope
                last.lastSeen = max(last.lastSeen, date)
                last.label = identity.label
                last.scope = identity.scope
                windows[windows.count - 1] = last
            } else {
                changesAttribution = true
                windows.append(
                    ProviderAccountIdentityWindow(
                        rawIdentity: identity.rawIdentity,
                        label: identity.label,
                        scope: identity.scope,
                        firstSeen: date,
                        lastSeen: date
                    )
                )
            }
            storage.state.windows[provider.rawValue] = windows
            persist(&storage, force: changesAttribution, at: date)
        }
    }

    /// Returns the single identity window covering `[start, end]`, or `nil`
    /// when the interval spans an account switch or the provider has no
    /// observed identity.
    public func attribution(
        for provider: AgentProvider,
        start: Date,
        end: Date
    ) -> ProviderAccountIdentityWindow? {
        let windows = storage.withLock { $0.state.windows[provider.rawValue] ?? [] }
        guard !windows.isEmpty else { return nil }
        let end = max(start, end)

        var covering: [ProviderAccountIdentityWindow] = []
        for (index, window) in windows.enumerated() {
            let coverageStart = window.firstSeen
            let coverageEnd = index + 1 < windows.count
                ? windows[index + 1].firstSeen
                : Date.distantFuture
            if start < coverageEnd && end >= coverageStart {
                covering.append(window)
            }
        }
        let identities = Set(covering.map(\.rawIdentity))
        guard identities.count == 1, let window = covering.last else { return nil }
        return window
    }

    private func persist(_ storage: inout Storage, force: Bool, at date: Date) {
        if !force, let lastPersistedAt = storage.lastPersistedAt,
           date.timeIntervalSince(lastPersistedAt) < Self.lastSeenPersistInterval {
            return
        }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(storage.state)
            try data.write(to: fileURL, options: .atomic)
            storage.lastPersistedAt = date
        } catch {
            // Best-effort journal: a failed write only delays attribution until
            // the next successful observation; never fail the refresh for it.
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
