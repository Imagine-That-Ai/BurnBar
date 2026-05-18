import Foundation
import Observation
import OpenBurnBarCore
import OpenBurnBarMedia

// MARK: - Agent Identity Registry (Hermes Square §6.2)
//
// Registry of every agent the user has access to. Seeds with the five
// built-ins on cold start; merges user-installed agents from a local
// JSON store; refreshes availability + last-7-days stats on demand from
// the existing services (HermesService, PiService, CLIAgentChatReader,
// MissionConsoleHost).
//
// Owned by `HermesSquareRoot` and shared into the view tree as an
// `@Observable` reference. Concurrency-safe to read from any view.

@MainActor
@Observable
final class AgentIdentityRegistry {
    static let shared = AgentIdentityRegistry()

    private(set) var identities: [AgentIdentity] = []
    private(set) var lastRefreshedAt: Date?
    private(set) var refreshError: String?

    /// Local persisted installs. Hydrated from `UserDefaults`.
    private var userInstalledManifests: [AgentManifest]

    /// Mercury Phase 8 — the paired Mac peer snapshot, set by
    /// `MercuryPeerSource` so the registry can resolve
    /// `device://paired-mac/<connectionID>` URIs to a synthesized
    /// `AgentIdentity` without polluting the persistent identities
    /// list. Reset to `nil` when the Mac goes offline; the tile reads
    /// the new availability automatically.
    var pairedMacPeer: MercuryPeer?

    private static let userInstallsKey = "square.installedManifests.v1"
    static let pairedMacURIPrefix = "device://paired-mac/"

    init(seed: [AgentIdentity] = AgentIdentity.defaultBuiltIns) {
        self.userInstalledManifests = Self.loadUserInstalls()
        self.identities = seed + userInstalledManifests.map { manifest in
            AgentIdentity(fromManifest: manifest, installSource: .userInstalled(manifestURL: manifest.agentURI))
        }
    }

    /// Look up by URI.
    func identity(for uri: String) -> AgentIdentity? {
        if let cached = identities.first(where: { $0.id == uri }) {
            return cached
        }
        if uri.hasPrefix(Self.pairedMacURIPrefix), let peer = pairedMacPeer {
            return synthesizedMacIdentity(from: peer, uri: uri)
        }
        return nil
    }

    /// Build the synthesized "My Mac" identity from the peer snapshot.
    /// Used by the pinned tile + Mercury Live sheet. Not stored in
    /// `identities` to avoid persisting an ephemeral peer in the
    /// long-lived registry.
    func synthesizedMacIdentity(
        from peer: MercuryPeer,
        uri: String? = nil
    ) -> AgentIdentity {
        let resolvedURI = uri ?? "\(Self.pairedMacURIPrefix)\(peer.connectionID)"
        let availability: AgentIdentity.Availability = peer.isOnline ? .online : .offline
        return AgentIdentity(
            id: resolvedURI,
            runtimeID: nil,
            displayName: peer.displayName.isEmpty ? "My Mac" : peer.displayName,
            glyph: "🖥",
            paletteHex: "8B9DC3", // mercury silver
            tier: .service,
            availability: availability,
            installSource: .builtIn,
            capabilities: .empty,
            dispatchTransport: .nativeRelay,
            personas: [],
            lastSevenDays: nil,
            lastRefreshedAt: peer.lastSeenAt,
            tagline: "Mirror, call, or send a file"
        )
    }

    /// Built-ins only.
    var builtIns: [AgentIdentity] {
        identities.filter { $0.installSource == .builtIn }
    }

    /// User-installed agents only.
    var userInstalled: [AgentIdentity] {
        identities.filter {
            if case .userInstalled = $0.installSource { return true }
            return false
        }
    }

    /// Refresh availability + 7-day stats for all identities. Pulls
    /// availability from `HermesService` / `PiService` (online when
    /// instantiated) and from `MissionConsoleHost` for the Mac-relay
    /// runtimes (online when their tile is present in the snapshot).
    /// Computes a per-runtime `AgentRecentStats` by filtering the host's
    /// runtimes + activeTiles + recentTicker.
    func refresh(
        hermesService: HermesService? = nil,
        piService: PiService? = nil,
        missionHost: MissionConsoleHost? = nil
    ) async {
        refreshError = nil
        let now = Date()
        let hostSnapshot = missionHost?.snapshot
        let runtimeAvailabilityByID: [String: AgentIdentity.Availability] = {
            guard let runtimes = hostSnapshot?.runtimes else { return [:] }
            return Dictionary(uniqueKeysWithValues: runtimes.map { ($0.id, Self.bridge(availability: $0.availability)) })
        }()
        identities = identities.map { existing in
            let availability: AgentIdentity.Availability
            switch existing.runtimeID {
            case .hermes:   availability = hermesService.map { _ in .online } ?? .unknown
            case .pi:       availability = piService.map { _ in .online } ?? .unknown
            case .claude:
                availability = runtimeAvailabilityByID["claude"] ?? existing.availability
            case .codex:
                availability = runtimeAvailabilityByID["codex"] ?? existing.availability
            case .openClaw:
                availability = runtimeAvailabilityByID["openclaw"] ?? existing.availability
            case .none:
                availability = existing.availability
            }
            let stats = hostSnapshot.flatMap { Self.computeStats(for: existing, in: $0) }
            return AgentIdentity(
                id: existing.id,
                runtimeID: existing.runtimeID,
                displayName: existing.displayName,
                glyph: existing.glyph,
                paletteHex: existing.paletteHex,
                tier: existing.tier,
                availability: availability,
                installSource: existing.installSource,
                capabilities: existing.capabilities,
                dispatchTransport: existing.dispatchTransport,
                personas: existing.personas,
                lastSevenDays: stats ?? existing.lastSevenDays,
                lastRefreshedAt: now,
                tagline: existing.tagline
            )
        }
        lastRefreshedAt = now
    }

    // MARK: - Mission Console → AgentRecentStats bridge

    private static func bridge(availability: MissionConsoleRuntime.Availability) -> AgentIdentity.Availability {
        switch availability {
        case .online:   return .online
        case .offline:  return .offline
        case .unknown:  return .unknown
        }
    }

    /// Derive a 7-day stat block for `identity` from a `MissionConsoleSnapshot`.
    /// Pulls per-runtime burn from the recent-ticker, and tile/mission
    /// counts from the live + recent state. Returns `nil` for identities
    /// whose runtime isn't represented in the snapshot so the brand zone
    /// honestly says "no telemetry yet" rather than zero-everything.
    private static func computeStats(
        for identity: AgentIdentity,
        in snapshot: MissionConsoleSnapshot
    ) -> AgentRecentStats? {
        guard let runtimeID = identity.runtimeID?.rawValue else { return nil }

        let normalizedRuntime = runtimeID.lowercased()
        let runtimeMatch: (MissionConsoleRuntime.ID?) -> Bool = { tileRuntime in
            guard let tileRuntime else { return false }
            return tileRuntime.lowercased() == normalizedRuntime
        }

        let activeForRuntime = snapshot.activeTiles.filter { runtimeMatch($0.runtimeID) }
        let recentForRuntime = snapshot.recentTicker.filter { runtimeMatch($0.runtimeID) }
        let runtimeRecord = snapshot.runtimes.first { $0.id.lowercased() == normalizedRuntime }

        // No signal at all — return nil to preserve "no telemetry yet" UX.
        if activeForRuntime.isEmpty && recentForRuntime.isEmpty && runtimeRecord == nil {
            return nil
        }

        let activeBurn = activeForRuntime.reduce(0.0) { $0 + $1.burnSoFarUSD }
        let medianBurn = runtimeRecord?.recentMedianBurnUSD ?? 0.0
        let sampleSize = runtimeRecord?.recentSampleSize ?? 0
        let totalBurn = activeBurn + medianBurn * Double(max(sampleSize, 0))

        let missionCount = max(sampleSize, activeForRuntime.count)
        let threadCount = Set(activeForRuntime.map(\.title)).count

        // Success rate: derived from the recent ticker — fraction of
        // finalAnswer entries vs error entries. Defaults to 1.0 when
        // we have no failures (optimistic-but-honest given that the
        // mission tile would otherwise have surfaced the failure).
        let answers = recentForRuntime.filter { $0.kind == .finalAnswer }.count
        let errors = recentForRuntime.filter { $0.kind == .error || $0.isError }.count
        let denom = max(answers + errors, 1)
        let successRate = Double(answers + (errors == 0 ? denom : 0)) / Double(denom * 2)
        // The expression above smooths to ~1.0 with zero errors and
        // ~answers/(answers+errors) once errors appear; clamp defensively.
        let clampedSuccess = max(0.0, min(1.0, errors == 0 ? 1.0 : Double(answers) / Double(answers + errors)))

        return AgentRecentStats(
            threadCount: threadCount,
            missionCount: missionCount,
            burnUSD: totalBurn,
            successRate: clampedSuccess,
            medianRoundtripSeconds: nil,
            windowDays: 7
        )
    }

    /// Install a manifest. Validates first, then writes to local store and
    /// merges into `identities`. Returns the new identity on success.
    @discardableResult
    func install(manifest: AgentManifest) throws -> AgentIdentity {
        try manifest.validate()
        // Avoid duplicate URIs.
        if let existing = identity(for: manifest.agentURI) {
            return existing
        }
        userInstalledManifests.append(manifest)
        Self.saveUserInstalls(userInstalledManifests)
        let identity = AgentIdentity(
            fromManifest: manifest,
            installSource: .userInstalled(manifestURL: manifest.agentURI)
        )
        identities.append(identity)
        return identity
    }

    /// Uninstall a user-installed agent. No-ops for built-ins.
    func uninstall(uri: String) {
        guard let idx = identities.firstIndex(where: { $0.id == uri }) else { return }
        guard identities[idx].installSource.canBeUninstalled else { return }
        identities.remove(at: idx)
        userInstalledManifests.removeAll { $0.agentURI == uri }
        Self.saveUserInstalls(userInstalledManifests)
    }

    /// Update the persisted personas for an agent. Used by the brand-zone
    /// persona editor.
    func updatePersonas(uri: String, personas: [AgentPersona]) {
        guard let idx = identities.firstIndex(where: { $0.id == uri }) else { return }
        let existing = identities[idx]
        identities[idx] = AgentIdentity(
            id: existing.id,
            runtimeID: existing.runtimeID,
            displayName: existing.displayName,
            glyph: existing.glyph,
            paletteHex: existing.paletteHex,
            tier: existing.tier,
            availability: existing.availability,
            installSource: existing.installSource,
            capabilities: existing.capabilities,
            dispatchTransport: existing.dispatchTransport,
            personas: personas.personasSanitized(),
            lastSevenDays: existing.lastSevenDays,
            lastRefreshedAt: Date(),
            tagline: existing.tagline
        )
    }

    // MARK: - Persistence

    private static func loadUserInstalls() -> [AgentManifest] {
        guard let data = UserDefaults.standard.data(forKey: userInstallsKey) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AgentManifest].self, from: data)) ?? []
    }

    private static func saveUserInstalls(_ manifests: [AgentManifest]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifests) else { return }
        UserDefaults.standard.set(data, forKey: userInstallsKey)
    }
}
