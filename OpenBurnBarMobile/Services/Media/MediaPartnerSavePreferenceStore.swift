import Foundation

/// Implements Decision 3 of the Mercury media plan: per-paired-Mac save
/// preferences for inbound image attachments. First image from a given
/// peer presents an action sheet (Photos / Files); subsequent images
/// from the same peer use the saved choice. Persistence: `UserDefaults`
/// keyed by the peer iroh `NodeId`.
///
/// Settings → Media → "Per-partner save preferences" surfaces the list +
/// per-row "Forget" + global "Forget all".
public actor MediaPartnerSavePreferenceStore {
    public enum SavePreference: String, Sendable, Codable, Equatable {
        case askEachTime
        case photos
        case files
    }

    public static let shared = MediaPartnerSavePreferenceStore()

    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "media.savePreference."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func preference(forPeerDeviceId peerDeviceId: String) -> SavePreference {
        let key = keyPrefix + peerDeviceId
        guard let raw = defaults.string(forKey: key),
              let value = SavePreference(rawValue: raw) else {
            return .askEachTime
        }
        return value
    }

    public func setPreference(
        _ preference: SavePreference,
        forPeerDeviceId peerDeviceId: String
    ) {
        let key = keyPrefix + peerDeviceId
        if preference == .askEachTime {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(preference.rawValue, forKey: key)
        }
    }

    public func forget(peerDeviceId: String) {
        defaults.removeObject(forKey: keyPrefix + peerDeviceId)
    }

    public func forgetAll() {
        let domain = defaults.dictionaryRepresentation()
        for key in domain.keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Snapshot of every paired Mac with a stored preference. Powers the
    /// Settings → Media UI.
    public func storedPartners() -> [(peerDeviceId: String, preference: SavePreference)] {
        let domain = defaults.dictionaryRepresentation()
        var result: [(String, SavePreference)] = []
        for (key, value) in domain {
            guard key.hasPrefix(keyPrefix) else { continue }
            let id = String(key.dropFirst(keyPrefix.count))
            if let raw = value as? String, let pref = SavePreference(rawValue: raw) {
                result.append((id, pref))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }
}
