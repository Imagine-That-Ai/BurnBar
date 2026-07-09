import CoreLocation
import Foundation
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

/// Coarse OS location → stable geography keys for community city-tier leaderboards.
/// Never persists or transmits raw coordinates.
struct CommunityResolvedGeo: Equatable, Sendable {
    /// Canonical `{CC}-{REGION}-{citySlug}` per `CommunityCityGeo`.
    let cityKey: String
    let countryCode: String
    let regionCode: String
    /// Profile `regionKey` (`{CC}-{REGION}`).
    let regionKey: String
}

enum CommunityLocationResolver {
    /// Fixed-locale reverse geocode (en_US_POSIX) so city names match across platforms.
    fileprivate static let geocodeLocale = Locale(identifier: "en_US_POSIX")

    @MainActor
    static func resolve() async -> CommunityResolvedGeo? {
        let session = LocationResolverSession()
        return await session.run()
    }
}

@MainActor
private final class LocationResolverSession: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CommunityResolvedGeo?, Never>?
    private var didFinish = false

    func run() async -> CommunityResolvedGeo? {
        await withCheckedContinuation { cont in
            continuation = cont
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            let status = manager.authorizationStatus
            switch status {
            case .notDetermined:
                #if os(iOS)
                manager.requestWhenInUseAuthorization()
                #else
                manager.requestAlwaysAuthorization()
                #endif
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .restricted, .denied:
                finish(nil)
            @unknown default:
                finish(nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard !didFinish else { return }
            switch self.manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.manager.requestLocation()
            case .denied, .restricted:
                finish(nil)
            case .notDetermined:
                break
            @unknown default:
                finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            Task { @MainActor in self.finish(nil) }
            return
        }
        Task { @MainActor in
            guard !self.didFinish else { return }
            let geo = await self.reverseGeocode(location)
            self.finish(geo)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    private func reverseGeocode(_ location: CLLocation) async -> CommunityResolvedGeo? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                location,
                preferredLocale: CommunityLocationResolver.geocodeLocale
            )
            guard let placemark = placemarks.first else { return nil }
            guard let country = placemark.isoCountryCode?.uppercased(), !country.isEmpty else { return nil }
            guard let regionCode = Self.regionSubdivisionCode(from: placemark), !regionCode.isEmpty else { return nil }
            let cityName = placemark.locality
                ?? placemark.subAdministrativeArea
                ?? placemark.administrativeArea
            guard let cityName, !cityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let slug = CommunityCityGeo.slugifyCity(cityName)
            guard !slug.isEmpty else { return nil }
            let cityKey = CommunityCityGeo.canonicalizeCityKey(
                cityName: cityName,
                countryCode: country,
                regionCode: regionCode
            )
            let regionKey = CommunityCityGeo.regionKey(countryCode: country, regionCode: regionCode)
            return CommunityResolvedGeo(
                cityKey: cityKey,
                countryCode: country,
                regionCode: regionCode,
                regionKey: regionKey
            )
        } catch {
            return nil
        }
    }

    /// ISO 3166-2 subdivision without country prefix (e.g. "CA", "BY").
    private static func regionSubdivisionCode(from placemark: CLPlacemark) -> String? {
        if let admin = placemark.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines),
           !admin.isEmpty,
           admin.count <= 3 {
            return admin.uppercased()
        }
        return nil
    }

    private func finish(_ value: CommunityResolvedGeo?) {
        guard !didFinish else { return }
        didFinish = true
        manager.delegate = nil
        continuation?.resume(returning: value)
        continuation = nil
    }
}
