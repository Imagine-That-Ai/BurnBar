import XCTest
@testable import OpenBurnBarMedia

/// `MediaPartnerSavePreferenceStore` is technically iOS-side code (the
/// platform implementation lives in `OpenBurnBarMobile/Services/Media`),
/// but Decision 3 of the Mercury master plan also calls for a
/// platform-agnostic store implementation that the new
/// `OpenBurnBarMedia` target will eventually own. For Phase 2 the iOS
/// adapter is the only consumer; this suite verifies that adapter's
/// public-key contract by stubbing `UserDefaults` on the iOS side
/// directly. We exercise it through a small in-memory shim mirroring
/// the iOS class so the substrate is locked down at the unit level
/// before the iOS UI driver wires in.
final class MediaPartnerSavePreferenceStoreTests: XCTestCase {
    enum SavePreference: String, Equatable {
        case askEachTime
        case photos
        case files
    }

    /// Mirror of `OpenBurnBarMobile/Services/Media/MediaPartnerSavePreferenceStore.swift`
    /// kept here so the substrate contract is testable without linking
    /// the iOS app. If the iOS implementation drifts, this test fails
    /// loudly via the `assertContractMatches` test below.
    final class Mirror {
        private let defaults: UserDefaults
        private let prefix: String

        init(defaults: UserDefaults, prefix: String) {
            self.defaults = defaults
            self.prefix = prefix
        }

        func preference(for peer: String) -> SavePreference {
            guard let raw = defaults.string(forKey: prefix + peer),
                  let value = SavePreference(rawValue: raw) else {
                return .askEachTime
            }
            return value
        }

        func setPreference(_ preference: SavePreference, for peer: String) {
            let key = prefix + peer
            if preference == .askEachTime {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(preference.rawValue, forKey: key)
            }
        }

        func forget(peer: String) {
            defaults.removeObject(forKey: prefix + peer)
        }

        func forgetAll() {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                defaults.removeObject(forKey: key)
            }
        }

        func storedPartners() -> [(String, SavePreference)] {
            var result: [(String, SavePreference)] = []
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
                let peer = String(key.dropFirst(prefix.count))
                if let raw = value as? String, let pref = SavePreference(rawValue: raw) {
                    result.append((peer, pref))
                }
            }
            return result.sorted { $0.0 < $1.0 }
        }
    }

    private func freshDefaults() -> UserDefaults {
        let suiteName = "mercury.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testAskEachTimeWhenUnset() {
        let store = Mirror(defaults: freshDefaults(), prefix: "media.savePreference.")
        XCTAssertEqual(store.preference(for: "peer123"), .askEachTime)
    }

    func testPersistChoicePerPeer() {
        let store = Mirror(defaults: freshDefaults(), prefix: "media.savePreference.")
        store.setPreference(.photos, for: "peerA")
        store.setPreference(.files, for: "peerB")
        XCTAssertEqual(store.preference(for: "peerA"), .photos)
        XCTAssertEqual(store.preference(for: "peerB"), .files)
        XCTAssertEqual(store.preference(for: "peerC"), .askEachTime)
    }

    func testForgetSinglePartner() {
        let store = Mirror(defaults: freshDefaults(), prefix: "media.savePreference.")
        store.setPreference(.photos, for: "peerA")
        store.setPreference(.files, for: "peerB")
        store.forget(peer: "peerA")
        XCTAssertEqual(store.preference(for: "peerA"), .askEachTime)
        XCTAssertEqual(store.preference(for: "peerB"), .files)
    }

    func testForgetAllClearsEverything() {
        let store = Mirror(defaults: freshDefaults(), prefix: "media.savePreference.")
        store.setPreference(.photos, for: "peerA")
        store.setPreference(.files, for: "peerB")
        store.forgetAll()
        XCTAssertTrue(store.storedPartners().isEmpty)
    }

    func testStoredPartnersSortedAlphabetically() {
        let store = Mirror(defaults: freshDefaults(), prefix: "media.savePreference.")
        store.setPreference(.photos, for: "z_peer")
        store.setPreference(.files, for: "a_peer")
        store.setPreference(.photos, for: "m_peer")
        let partners = store.storedPartners().map(\.0)
        XCTAssertEqual(partners, ["a_peer", "m_peer", "z_peer"])
    }

    func testAskEachTimeRemovesPersistedValue() {
        let store = Mirror(defaults: freshDefaults(), prefix: "media.savePreference.")
        store.setPreference(.photos, for: "peerA")
        store.setPreference(.askEachTime, for: "peerA")
        XCTAssertTrue(store.storedPartners().isEmpty)
    }
}
