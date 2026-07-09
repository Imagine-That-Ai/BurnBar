import Foundation
import OpenBurnBarAnalytics
import OpenBurnBarCore
import OpenBurnBarFirestoreModels
#if canImport(Combine)
import Combine
#endif

// MARK: - Local L2 tier ladder (mirrors FirestoreCommunityTierConsent strings)

struct CommunityLocalTierConsent: Equatable, Sendable {
    var world: FirestoreConsentTriState = .unset
    var country: FirestoreConsentTriState = .unset
    var region: FirestoreConsentTriState = .unset
    var city: FirestoreConsentTriState = .unset
}

/// Tri-state community consent for the iOS host — mirrors
/// `AnalyticsConsentStore` / `OpenBurnBarCore` analytics patterns.
///
/// L1 private analytics, L2 rankings (+ per-tier ladder), L3 looking glass,
/// and coarse location are persisted locally until `joinCommunity` writes the
/// server doc. Server treats `.unset` and `.declined` identically (fail closed).
@MainActor
final class CommunityConsentStore: ObservableObject {
    static let shared = CommunityConsentStore()

    enum Storage {
        static let suiteName = AnalyticsConsentStorage.appGroupIdentifier
        static let l1Key = "communityConsent.l1Analytics"
        static let l2Key = "communityConsent.l2Rankings"
        static let l3Key = "communityConsent.l3LookingGlass"
        static let locationKey = "communityConsent.location"
        static let tierWorldKey = "communityConsent.tier.world"
        static let tierCountryKey = "communityConsent.tier.country"
        static let tierRegionKey = "communityConsent.tier.region"
        static let tierCityKey = "communityConsent.tier.city"
        static let geoCityKey = "communityConsent.geo.cityKey"
        static let geoCountryKey = "communityConsent.geo.countryCode"
        static let geoRegionKey = "communityConsent.geo.regionKey"
    }

#if canImport(Combine)
    @Published private(set) var l1Analytics: FirestoreConsentTriState {
        didSet { persist(l1Analytics, key: Storage.l1Key) }
    }
    @Published private(set) var l2Rankings: FirestoreConsentTriState {
        didSet { persist(l2Rankings, key: Storage.l2Key) }
    }
    @Published private(set) var l3LookingGlass: FirestoreConsentTriState {
        didSet { persist(l3LookingGlass, key: Storage.l3Key) }
    }
    @Published private(set) var locationConsent: FirestoreConsentTriState {
        didSet {
            persist(locationConsent, key: Storage.locationKey)
            if locationConsent != .granted {
                clearResolvedGeoIfCityTierOff()
            } else {
                Task { await refreshGeoFromOSIfNeeded() }
            }
        }
    }
    @Published private(set) var l2Tiers: CommunityLocalTierConsent {
        didSet {
            persist(l2Tiers.world, key: Storage.tierWorldKey)
            persist(l2Tiers.country, key: Storage.tierCountryKey)
            persist(l2Tiers.region, key: Storage.tierRegionKey)
            persist(l2Tiers.city, key: Storage.tierCityKey)
        }
    }
    @Published private(set) var resolvedCityKey: String? {
        didSet { persistOptional(resolvedCityKey, key: Storage.geoCityKey) }
    }
    @Published private(set) var resolvedCountryCode: String? {
        didSet { persistOptional(resolvedCountryCode, key: Storage.geoCountryKey) }
    }
    @Published private(set) var resolvedRegionKey: String? {
        didSet { persistOptional(resolvedRegionKey, key: Storage.geoRegionKey) }
    }
#else
    private(set) var l1Analytics: FirestoreConsentTriState
    private(set) var l2Rankings: FirestoreConsentTriState
    private(set) var l3LookingGlass: FirestoreConsentTriState
    private(set) var locationConsent: FirestoreConsentTriState
    private(set) var l2Tiers: CommunityLocalTierConsent
    private(set) var resolvedCityKey: String?
    private(set) var resolvedCountryCode: String?
    private(set) var resolvedRegionKey: String?
#endif

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let resolved = defaults
            ?? UserDefaults(suiteName: Storage.suiteName)
            ?? .standard
        self.defaults = resolved
        l1Analytics = Self.loadTriState(key: Storage.l1Key, defaults: resolved)
        l2Rankings = Self.loadTriState(key: Storage.l2Key, defaults: resolved)
        l3LookingGlass = Self.loadTriState(key: Storage.l3Key, defaults: resolved)
        locationConsent = Self.loadTriState(key: Storage.locationKey, defaults: resolved)
        l2Tiers = CommunityLocalTierConsent(
            world: Self.loadTriState(key: Storage.tierWorldKey, defaults: resolved),
            country: Self.loadTriState(key: Storage.tierCountryKey, defaults: resolved),
            region: Self.loadTriState(key: Storage.tierRegionKey, defaults: resolved),
            city: Self.loadTriState(key: Storage.tierCityKey, defaults: resolved)
        )
        resolvedCityKey = Self.loadOptional(key: Storage.geoCityKey, defaults: resolved)
        resolvedCountryCode = Self.loadOptional(key: Storage.geoCountryKey, defaults: resolved)
        resolvedRegionKey = Self.loadOptional(key: Storage.geoRegionKey, defaults: resolved)
    }

    var participatesInRankings: Bool { l2Rankings == .granted }

    func setL1(_ state: FirestoreConsentTriState) { l1Analytics = state }
    func setL2Rankings(_ state: FirestoreConsentTriState) { l2Rankings = state }
    func setL3(_ state: FirestoreConsentTriState) { l3LookingGlass = state }
    func setLocation(_ state: FirestoreConsentTriState) { locationConsent = state }

    func setTier(_ tier: FirestoreGeographyTier, state: FirestoreConsentTriState) {
        switch tier {
        case .world: l2Tiers.world = state
        case .country: l2Tiers.country = state
        case .region: l2Tiers.region = state
        case .city:
            l2Tiers.city = state
            if state == .granted {
                Task { await refreshGeoFromOSIfNeeded() }
            } else {
                clearResolvedGeo()
            }
        }
    }

    func tierState(_ tier: FirestoreGeographyTier) -> FirestoreConsentTriState {
        switch tier {
        case .world: l2Tiers.world
        case .country: l2Tiers.country
        case .region: l2Tiers.region
        case .city: l2Tiers.city
        }
    }

    func refreshGeoFromOSIfNeeded() async {
        guard l2Tiers.city == .granted, locationConsent == .granted else { return }
        guard let geo = await CommunityLocationResolver.resolve() else { return }
        resolvedCityKey = geo.cityKey
        resolvedCountryCode = geo.countryCode
        resolvedRegionKey = geo.regionKey
    }

    /// Apply server consent doc (owner read); does not downgrade granted local prefs silently.
    func applyServerConsent(_ doc: FirestoreCommunityConsentDoc) {
        l1Analytics = FirestoreConsentTriState(rawValue: doc.l1Analytics) ?? .unset
        l2Rankings = FirestoreConsentTriState(rawValue: doc.l2Rankings) ?? .unset
        l3LookingGlass = FirestoreConsentTriState(rawValue: doc.l3LookingGlass) ?? .unset
        locationConsent = FirestoreConsentTriState(rawValue: doc.locationConsent) ?? .unset
        l2Tiers = CommunityLocalTierConsent(
            world: FirestoreConsentTriState(rawValue: doc.l2Tiers.world) ?? .unset,
            country: FirestoreConsentTriState(rawValue: doc.l2Tiers.country) ?? .unset,
            region: FirestoreConsentTriState(rawValue: doc.l2Tiers.region) ?? .unset,
            city: FirestoreConsentTriState(rawValue: doc.l2Tiers.city) ?? .unset
        )
    }

    func revokeAll() {
        l1Analytics = .declined
        l2Rankings = .declined
        l3LookingGlass = .declined
        locationConsent = .declined
        l2Tiers = CommunityLocalTierConsent(
            world: .declined, country: .declined, region: .declined, city: .declined
        )
        clearResolvedGeo()
    }

    func joinPayload(
        profile: FirestoreCommunityProfileDoc?
    ) -> [String: String] {
        func wire(_ state: FirestoreConsentTriState) -> String {
            state == .granted ? "granted" : "declined"
        }
        var payload: [String: String] = [
            "l1Analytics": wire(l1Analytics),
            "l2Rankings": wire(l2Rankings),
            "l2World": wire(l2Tiers.world),
            "l2Country": wire(l2Tiers.country),
            "l2Region": wire(l2Tiers.region),
            "l2City": wire(l2Tiers.city),
            "locationConsent": wire(locationConsent),
            "l3LookingGlass": wire(l3LookingGlass),
            "timezone": TimeZone.current.identifier,
            "locale": Locale.current.identifier,
        ]
        let profileCountry = profile?.countryCode
        let profileRegion = profile?.regionKey
        let profileCity = profile?.cityKey
        let profileHandle = profile?.handle
        let effectiveCountry = profileCountry ?? resolvedCountryCode
        let effectiveRegion = profileRegion ?? resolvedRegionKey
        let effectiveCity = profileCity ?? resolvedCityKey
        if l2Tiers.country == .granted, let effectiveCountry { payload["countryCode"] = effectiveCountry }
        if l2Tiers.region == .granted, let effectiveRegion { payload["regionKey"] = effectiveRegion }
        if l2Tiers.city == .granted, locationConsent == .granted, let effectiveCity { payload["cityKey"] = effectiveCity }
        if let profileHandle { payload["handle"] = profileHandle }
        return payload
    }

    private static func loadTriState(key: String, defaults: UserDefaults) -> FirestoreConsentTriState {
        guard let raw = defaults.string(forKey: key) else { return .unset }
        return FirestoreConsentTriState(rawValue: raw) ?? .unset
    }

    private static func loadOptional(key: String, defaults: UserDefaults) -> String? {
        let raw = defaults.string(forKey: key) ?? ""
        return raw.isEmpty ? nil : raw
    }

    private func persist(_ state: FirestoreConsentTriState, key: String) {
        defaults.set(state.rawValue, forKey: key)
    }

    private func persistOptional(_ value: String?, key: String) {
        defaults.set(value ?? "", forKey: key)
    }

    private func clearResolvedGeo() {
        resolvedCityKey = nil
        resolvedCountryCode = nil
        resolvedRegionKey = nil
    }

    private func clearResolvedGeoIfCityTierOff() {
        if l2Tiers.city != .granted || locationConsent != .granted {
            clearResolvedGeo()
        }
    }
}