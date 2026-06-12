import Foundation
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Owns the per-device personalization map and exposes a SwiftUI
/// `Binding` for the active connection. Stored as a single Codable
/// dictionary under `@AppStorage("mercury.personalization.v1")`.
///
/// The store also resolves the live accent `Color` for a peer: when
/// the per-device setting is `.autoFromWallpaper`, the sampled color
/// from `WallpaperAccentSampler` is used; otherwise the static palette
/// color is returned. Sampling is cached by `connectionID` + base64
/// payload identity so we don't re-sample on every render.
@MainActor
final class MercuryPersonalizationStore: ObservableObject {
    static let shared = MercuryPersonalizationStore()

    private static let storageKey = "mercury.personalization.v1"
    private static let legacyTileKey = "mercuryPinnedTileEnabled"
    private static let legacyWallpaperKey = "mercuryMimicLoginBackground"

    @Published private(set) var snapshots: [String: MercuryDevicePersonalization] = [:]

    private let defaults: UserDefaults
    private var sampledAccentCache: [String: (basisHash: Int, color: Color)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshots = Self.load(from: defaults)
    }

    // MARK: - Lookup

    func snapshot(for connectionID: String) -> MercuryDevicePersonalization {
        if let existing = snapshots[connectionID] { return existing }
        return migratedDefault()
    }

    /// SwiftUI two-way binding for the connection. Reading returns the
    /// stored snapshot or the migrated default; writing persists.
    func binding(for connectionID: String) -> Binding<MercuryDevicePersonalization> {
        Binding(
            get: { [weak self] in
                self?.snapshot(for: connectionID) ?? .defaultForFirstRun
            },
            set: { [weak self] newValue in
                self?.update(connectionID: connectionID, value: newValue)
            }
        )
    }

    func update(connectionID: String, value: MercuryDevicePersonalization) {
        snapshots[connectionID] = value
        persist()
    }

    /// Convenience for ad-hoc mutations (e.g. toggling a single field
    /// from a SwiftUI gesture handler).
    func mutate(
        connectionID: String,
        _ transform: (inout MercuryDevicePersonalization) -> Void
    ) {
        var current = snapshot(for: connectionID)
        transform(&current)
        update(connectionID: connectionID, value: current)
    }

    // MARK: - Derived values

    /// Effective display name for the header card. Falls back to the
    /// peer's advertised display name when the user has not picked a
    /// custom nickname.
    func effectiveNickname(for connectionID: String, fallback: String) -> String {
        let nickname = snapshot(for: connectionID).nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nickname, !nickname.isEmpty { return nickname }
        return fallback
    }

    /// Resolves the user's accent for a peer into a concrete `Color`.
    /// `.autoFromWallpaper` consults `WallpaperAccentSampler` and caches
    /// per (connectionID, wallpaper payload) so subsequent reads are
    /// O(1).
    func resolvedAccent(for connectionID: String, wallpaperBase64: String?) -> Color {
        let snapshot = snapshot(for: connectionID)
        switch snapshot.accent {
        case .autoFromWallpaper:
            return sampledAccent(connectionID: connectionID, base64: wallpaperBase64)
        default:
            return snapshot.accent.staticColor
        }
    }

    /// Returns a small ordered set of suggestion nicknames derived from
    /// the peer's display name. Used by the nickname picker to seed
    /// quick chips below the text field.
    func nicknameSuggestions(for displayName: String) -> [String] {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var pool: [String] = []
        // Strip a leading possessive ("Alberto's MacBook Pro" → "MacBook Pro").
        if let apos = trimmed.range(of: "’s ") ?? trimmed.range(of: "'s ") {
            pool.append(String(trimmed[apos.upperBound...]))
        }
        let lower = trimmed.lowercased()
        if lower.contains("macbook") { pool.append("MacBook") }
        if lower.contains("mac mini") { pool.append("Mac mini") }
        if lower.contains("mac studio") { pool.append("Mac Studio") }
        if lower.contains("imac") { pool.append("iMac") }
        pool.append(contentsOf: ["Studio Mac", "The Forge", "Home Base", "The Workbench"])
        var seen: Set<String> = [trimmed]
        return Array(pool.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(4))
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(snapshots)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            // Best-effort — we don't want a personalization write to
            // crash the app. The in-memory snapshot is still authoritative
            // for this session.
        }
    }

    private static func load(from defaults: UserDefaults) -> [String: MercuryDevicePersonalization] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: MercuryDevicePersonalization].self, from: data)) ?? [:]
    }

    /// On first-touch for a new device, fold the legacy `@AppStorage`
    /// toggles into the default so existing users don't lose their
    /// preferences silently. Read-only — does not mutate the defaults.
    private func migratedDefault() -> MercuryDevicePersonalization {
        var value = MercuryDevicePersonalization.defaultForFirstRun
        if defaults.object(forKey: Self.legacyTileKey) != nil {
            value.showHermesSquareTile = defaults.bool(forKey: Self.legacyTileKey)
        }
        if defaults.object(forKey: Self.legacyWallpaperKey) != nil {
            value.mimicLoginBackground = defaults.bool(forKey: Self.legacyWallpaperKey)
        }
        return value
    }

    // MARK: - Accent sampling cache

    private func sampledAccent(connectionID: String, base64: String?) -> Color {
        let basisHash = base64?.hashValue ?? 0
        if let cached = sampledAccentCache[connectionID], cached.basisHash == basisHash {
            return cached.color
        }
        let resolved = WallpaperAccentSampler.dominantAccent(fromBase64: base64) ?? MercuryAccent.blue.staticColor
        sampledAccentCache[connectionID] = (basisHash, resolved)
        return resolved
    }
}
