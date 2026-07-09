import Combine
import Foundation
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

/// Tri-state community consent — L1 private analytics, L2 rankings (per geography tier), L3 Looking Glass.
///
/// Defaults are `.unset` for every ladder and tier. Server treats `.unset` and `.declined` identically (fail closed).
/// Modeled on `AnalyticsConsentStore`: `UserDefaults`-backed, `@MainActor` `ObservableObject`, persists on every change.
enum CommunityConsentLadder: String, Sendable, CaseIterable {
    case unset
    case granted
    case declined
}

@MainActor
final class CommunityConsentStore: ObservableObject {
    static let l1Key = "communityConsent.l1Analytics"
    static let l2Key = "communityConsent.l2Rankings"
    static let l3Key = "communityConsent.l3LookingGlass"
    static let locationKey = "communityConsent.location"
    static let tierWorldKey = "communityConsent.l2.world"
    static let tierCountryKey = "communityConsent.l2.country"
    static let tierRegionKey = "communityConsent.l2.region"
    static let tierCityKey = "communityConsent.l2.city"
    static let geoCityKey = "communityConsent.geo.cityKey"
    static let geoCountryKey = "communityConsent.geo.countryCode"
    static let geoRegionKey = "communityConsent.geo.regionKey"

    @Published private(set) var l1Analytics: CommunityConsentLadder {
        didSet { persist(l1Analytics, forKey: Self.l1Key) }
    }
    @Published private(set) var l2Rankings: CommunityConsentLadder {
        didSet { persist(l2Rankings, forKey: Self.l2Key) }
    }
    @Published private(set) var l3LookingGlass: CommunityConsentLadder {
        didSet { persist(l3LookingGlass, forKey: Self.l3Key) }
    }
    @Published private(set) var locationConsent: CommunityConsentLadder {
        didSet {
            persist(locationConsent, forKey: Self.locationKey)
            if locationConsent != .granted {
                clearResolvedGeoIfCityTierOff()
            } else {
                Task { await refreshGeoFromOSIfNeeded() }
            }
        }
    }
    @Published private(set) var l2World: CommunityConsentLadder {
        didSet { persist(l2World, forKey: Self.tierWorldKey) }
    }
    @Published private(set) var l2Country: CommunityConsentLadder {
        didSet { persist(l2Country, forKey: Self.tierCountryKey) }
    }
    @Published private(set) var l2Region: CommunityConsentLadder {
        didSet { persist(l2Region, forKey: Self.tierRegionKey) }
    }
    @Published private(set) var l2City: CommunityConsentLadder {
        didSet {
            persist(l2City, forKey: Self.tierCityKey)
            if l2City != .granted {
                clearResolvedGeo()
            } else {
                Task { await refreshGeoFromOSIfNeeded() }
            }
        }
    }

    @Published private(set) var resolvedCityKey: String? {
        didSet { persistOptional(resolvedCityKey, forKey: Self.geoCityKey) }
    }
    @Published private(set) var resolvedCountryCode: String? {
        didSet { persistOptional(resolvedCountryCode, forKey: Self.geoCountryKey) }
    }
    @Published private(set) var resolvedRegionKey: String? {
        didSet { persistOptional(resolvedRegionKey, forKey: Self.geoRegionKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        l1Analytics = Self.load(defaults, key: Self.l1Key)
        l2Rankings = Self.load(defaults, key: Self.l2Key)
        l3LookingGlass = Self.load(defaults, key: Self.l3Key)
        locationConsent = Self.load(defaults, key: Self.locationKey)
        l2World = Self.load(defaults, key: Self.tierWorldKey)
        l2Country = Self.load(defaults, key: Self.tierCountryKey)
        l2Region = Self.load(defaults, key: Self.tierRegionKey)
        l2City = Self.load(defaults, key: Self.tierCityKey)
        resolvedCityKey = Self.loadOptional(defaults, key: Self.geoCityKey)
        resolvedCountryCode = Self.loadOptional(defaults, key: Self.geoCountryKey)
        resolvedRegionKey = Self.loadOptional(defaults, key: Self.geoRegionKey)
    }

    func tierConsent(_ tier: FirestoreGeographyTier) -> CommunityConsentLadder {
        switch tier {
        case .world: return l2World
        case .country: return l2Country
        case .region: return l2Region
        case .city: return l2City
        }
    }

    func setL1(_ value: CommunityConsentLadder) { l1Analytics = value }
    func setL2(_ value: CommunityConsentLadder) { l2Rankings = value }
    func setL3(_ value: CommunityConsentLadder) { l3LookingGlass = value }
    func setLocation(_ value: CommunityConsentLadder) { locationConsent = value }

    func setTier(_ tier: FirestoreGeographyTier, _ value: CommunityConsentLadder) {
        switch tier {
        case .world: l2World = value
        case .country: l2Country = value
        case .region: l2Region = value
        case .city: l2City = value
        }
    }

    func refreshGeoFromOSIfNeeded() async {
        guard l2City == .granted, locationConsent == .granted else { return }
        guard let geo = await CommunityLocationResolver.resolve() else { return }
        guard l2City == .granted, locationConsent == .granted else { return }
        resolvedCityKey = geo.cityKey
        resolvedCountryCode = geo.countryCode
        resolvedRegionKey = geo.regionKey
    }

    /// Revoke all ladders and tiers locally (server tombstone via `CommunityService.revokeParticipation`).
    func revokeAllLocally() {
        l1Analytics = .declined
        l2Rankings = .declined
        l3LookingGlass = .declined
        locationConsent = .declined
        l2World = .declined
        l2Country = .declined
        l2Region = .declined
        l2City = .declined
        clearResolvedGeo()
    }

    func joinPayload(
        handle: String?,
        countryCode: String?,
        regionKey: String?,
        cityKey: String?
    ) -> CommunityJoinRequest {
        let effectiveCountry = countryCode ?? resolvedCountryCode
        let effectiveRegion = regionKey ?? resolvedRegionKey
        let effectiveCity = cityKey ?? resolvedCityKey
        return CommunityJoinRequest(
            l1Analytics: triStateString(l1Analytics),
            l2Rankings: triStateString(l2Rankings),
            l2World: triStateString(l2World),
            l2Country: triStateString(l2Country),
            l2Region: triStateString(l2Region),
            l2City: triStateString(l2City),
            locationConsent: triStateString(locationConsent),
            l3LookingGlass: triStateString(l3LookingGlass),
            timezone: TimeZone.current.identifier,
            locale: Locale.current.identifier,
            handle: handle?.nilIfBlank,
            countryCode: l2Country == .granted ? effectiveCountry : nil,
            regionKey: l2Region == .granted ? effectiveRegion : nil,
            cityKey: l2City == .granted && locationConsent == .granted ? effectiveCity : nil
        )
    }

    private func triStateString(_ value: CommunityConsentLadder) -> String {
        value == .granted ? "granted" : "declined"
    }

    private func clearResolvedGeo() {
        resolvedCityKey = nil
        resolvedCountryCode = nil
        resolvedRegionKey = nil
    }

    private func clearResolvedGeoIfCityTierOff() {
        if l2City != .granted || locationConsent != .granted {
            clearResolvedGeo()
        }
    }

    private static func load(_ defaults: UserDefaults, key: String) -> CommunityConsentLadder {
        guard let raw = defaults.string(forKey: key),
              let ladder = CommunityConsentLadder(rawValue: raw) else { return .unset }
        return ladder
    }

    private static func loadOptional(_ defaults: UserDefaults, key: String) -> String? {
        let raw = defaults.string(forKey: key) ?? ""
        return raw.isEmpty ? nil : raw
    }

    private func persist(_ value: CommunityConsentLadder, forKey key: String) {
        defaults.set(value.rawValue, forKey: key)
    }

    private func persistOptional(_ value: String?, forKey key: String) {
        defaults.set(value ?? "", forKey: key)
    }
}
