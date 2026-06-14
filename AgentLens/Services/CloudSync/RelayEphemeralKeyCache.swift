import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

// MARK: - Relay shared types

struct ClaimedRelayRequest: @unchecked Sendable {
    let data: [String: Any]
}

final class RelayEphemeralKeyCache: Sendable {
    static let shared = RelayEphemeralKeyCache()

    private let keys = Locked<[String: Data]>([:])

    func data(for key: String, generate: () -> Data) -> Data {
        keys.withLock { keys in
            if let existing = keys[key] {
                return existing
            }
            let fresh = generate()
            keys[key] = fresh
            return fresh
        }
    }

    func existingData(for key: String) -> Data? {
        keys.withLock { $0[key] }
    }
}
