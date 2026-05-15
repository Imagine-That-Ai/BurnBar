import Foundation
import Observation
import OpenBurnBarCore

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

    private static let userInstallsKey = "square.installedManifests.v1"

    init(seed: [AgentIdentity] = AgentIdentity.defaultBuiltIns) {
        self.userInstalledManifests = Self.loadUserInstalls()
        self.identities = seed + userInstalledManifests.map { manifest in
            AgentIdentity(fromManifest: manifest, installSource: .userInstalled(manifestURL: manifest.agentURI))
        }
    }

    /// Look up by URI.
    func identity(for uri: String) -> AgentIdentity? {
        identities.first { $0.id == uri }
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
    /// availability from existing services where possible; leaves
    /// `.unknown` where the source doesn't report.
    func refresh(
        hermesService: HermesService? = nil,
        piService: PiService? = nil
    ) async {
        refreshError = nil
        // Mostly local data so far; this scaffold leaves heavy hydration
        // (mission burn aggregation, mission counts) for a follow-up.
        let now = Date()
        identities = identities.map { existing in
            let availability: AgentIdentity.Availability
            switch existing.runtimeID {
            case .hermes:   availability = hermesService.map { _ in .online } ?? .unknown
            case .pi:       availability = piService.map { _ in .online } ?? .unknown
            case .claude, .codex, .openClaw:
                // Mac-relay runtimes: availability matches the Mac listener
                // heartbeat — surfaced by the mission console host. The
                // registry treats them as `.unknown` until the host
                // explicitly publishes a state.
                availability = existing.availability
            case .none:
                availability = existing.availability
            }
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
                lastSevenDays: existing.lastSevenDays,
                lastRefreshedAt: now,
                tagline: existing.tagline
            )
        }
        lastRefreshedAt = now
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
