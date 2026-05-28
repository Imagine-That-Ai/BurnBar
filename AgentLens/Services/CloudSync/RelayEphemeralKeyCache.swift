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

final class RelayEphemeralKeyCache: @unchecked Sendable {
    static let shared = RelayEphemeralKeyCache()

    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    func data(for key: String, generate: () -> Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let existing = keys[key] {
            return existing
        }
        let fresh = generate()
        keys[key] = fresh
        return fresh
    }

    func existingData(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return keys[key]
    }
}
