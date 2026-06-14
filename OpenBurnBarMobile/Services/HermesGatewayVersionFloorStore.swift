import Foundation
import OpenBurnBarCore
import Security

/// # Gateway envelope-version FLOOR pinning (T-CRY-01 — anti-downgrade trust root)
///
/// **Threat closed.** The phone seals `hermes_gateway_events` to the agent and
/// opens `hermes_gateway_messages` from the agent. The wrap-protocol version (v2
/// authenticated 2-DH vs v3 RFC 9180 HPKE Auth) is selected from
/// `HermesGatewayClientRecord` fields the *server* controls
/// (`supportsRelayEnvelopeVersions` / `preferredRelayEnvelopeVersion`). A
/// compromised relay/Firestore backend — in scope for the E2EE threat model —
/// could advertise v2 again for a peer that had already proven v3 capability,
/// silently downgrading the channel to the weaker suite. The per-event seal and
/// the per-message open both honour whatever the doc currently advertises, so
/// nothing on the device remembered that v3 had ever been reached.
///
/// **Fix.** The phone holds an authoritative *high-water* of the highest gateway
/// envelope version it has ever observed for a peer. On the first time we observe
/// a v3-capable peer for a `clientId`, v3 is pinned as the floor in the iOS
/// Keychain (`WhenUnlockedThisDeviceOnly`, never synced). Every later seal/open
/// compares the version that *would* be used (for a seal) or that *arrived* (for
/// an open) against the pinned floor:
///
/// - a version **at or above** the floor is admitted (the steady state);
/// - a version **below** the floor is **refused** — a downgrade is a possible
///   MITM and the operator must deliberately re-pair (which clears the floor),
///   exactly the rotation contract ``HermesGatewayAgentKeyPinStore`` /
///   ``IrohHostKeyPinStore`` use;
/// - a Keychain read/write failure is **fail-closed** (refuse) rather than
///   trusting a phantom floor.
///
/// The high-water only ever ratchets *up* (`raiseFloorIfObserved`): once v3 is
/// seen it cannot be un-seen by a later server advertisement. This is the exact
/// mirror of the host-/controller-/agent-key pins, applied to the protocol
/// version instead of the key bytes.
///
/// The pure decision lives over an injectable backing seam
/// (``HermesGatewayPinBacking``, reused from ``HermesGatewayRelayKeypair``) so
/// every branch is unit-testable with an in-memory backing on a CI runner with
/// no Keychain entitlement; the shipping app always uses the Keychain.
struct HermesGatewayVersionFloorStore: Sendable {
    /// The outcome of checking a candidate envelope version against the floor.
    enum FloorResult: Equatable {
        /// No floor existed; the candidate was recorded as the first floor.
        case pinnedFirstUse(floor: Int)
        /// The candidate is at or above the pinned floor — safe to proceed.
        case atOrAboveFloor(floor: Int)
        /// The candidate is below the pinned floor — refuse (possible downgrade).
        case belowFloor(floor: Int, candidate: Int)
        /// The Keychain could not be read/written; treat as fail-closed (refuse).
        case unknownKeychainError(status: Int)

        /// True only when it is safe to seal/open at the candidate version.
        var allows: Bool {
            switch self {
            case .pinnedFirstUse, .atOrAboveFloor: return true
            case .belowFloor, .unknownKeychainError: return false
            }
        }
    }

    private let backing: HermesGatewayPinBacking

    private enum VersionFloorLoad {
        case found(Int)
        case absent
        case unreadable(OSStatus)
    }

    /// Production uses the device Keychain (a distinct `service` from the
    /// agent-key pin so the two trust roots never collide); tests inject an
    /// in-memory backing so the floor logic runs without Keychain entitlements.
    init(backing: HermesGatewayPinBacking = HermesGatewayVersionFloorKeychainBacking()) {
        self.backing = backing
    }

    /// Account scope is `uid|clientId` so a re-used `clientId` across accounts
    /// (or a stale floor from a different signed-in user) never matches.
    private func account(uid: String, clientId: String) -> String {
        "\(uid)|\(clientId)"
    }

    /// Verify a candidate envelope version against the pinned floor, raising the
    /// floor on first use. Pure over the backing seam; safe to call on every
    /// seal and every open.
    func verifyAndPin(candidateVersion candidate: Int, uid: String, clientId: String) -> FloorResult {
        switch loadFloor(uid: uid, clientId: clientId) {
        case .found(let floor):
            if candidate >= floor {
                // Ratchet the high-water up if this candidate raised it (e.g. a
                // first v3 seal after a v2 floor). FAIL-CLOSED on a write failure.
                if candidate > floor {
                    let status = saveFloor(candidate, uid: uid, clientId: clientId)
                    guard status == errSecSuccess else {
                        return .unknownKeychainError(status: Int(status))
                    }
                    return .atOrAboveFloor(floor: candidate)
                }
                return .atOrAboveFloor(floor: floor)
            }
            return .belowFloor(floor: floor, candidate: candidate)
        case .absent:
            // First trust: pin the candidate as the floor, FAIL-CLOSED on a write
            // failure. A silently-unpersisted floor would let the next seal/open
            // re-pin from a relay-advertised version (reopening the downgrade
            // window) and would let the floor appear set while not durable.
            let status = saveFloor(candidate, uid: uid, clientId: clientId)
            guard status == errSecSuccess else {
                return .unknownKeychainError(status: Int(status))
            }
            return .pinnedFirstUse(floor: candidate)
        case .unreadable(let status):
            return .unknownKeychainError(status: Int(status))
        }
    }

    /// Raise the high-water to `observed` if it is higher than the current floor,
    /// without rejecting anything. Used to record an observed v3 capability for a
    /// peer (e.g. from the client doc's advertised versions) before a seal even
    /// picks a version, so a subsequent v2-only advertisement is refused.
    /// Returns the floor in effect after the call, or `nil` on a Keychain error.
    @discardableResult
    func raiseFloorIfObserved(_ observed: Int, uid: String, clientId: String) -> Int? {
        switch loadFloor(uid: uid, clientId: clientId) {
        case .found(let floor):
            guard observed > floor else { return floor }
            return saveFloor(observed, uid: uid, clientId: clientId) == errSecSuccess ? observed : nil
        case .absent:
            return saveFloor(observed, uid: uid, clientId: clientId) == errSecSuccess ? observed : nil
        case .unreadable:
            return nil
        }
    }

    /// The currently pinned floor for a client, or `nil` if none / unreadable.
    func pinnedFloor(uid: String, clientId: String) -> Int? {
        if case .found(let floor) = loadFloor(uid: uid, clientId: clientId) { return floor }
        return nil
    }

    /// Clear the floor for a client so a deliberate operator-initiated re-pair can
    /// re-establish the high-water afresh. The only sanctioned reset path — no
    /// relay-supplied advertisement can lower a floor in place.
    func clearFloor(uid: String, clientId: String) {
        backing.delete(account: account(uid: uid, clientId: clientId))
    }

    // MARK: - Backing delegation

    private func loadFloor(uid: String, clientId: String) -> VersionFloorLoad {
        switch backing.load(account: account(uid: uid, clientId: clientId)) {
        case .found(let value):
            guard let floor = Int(value) else { return .unreadable(errSecDecode) }
            return .found(floor)
        case .absent:
            return .absent
        case .unreadable(let status):
            return .unreadable(status)
        }
    }

    @discardableResult
    private func saveFloor(_ version: Int, uid: String, clientId: String) -> OSStatus {
        backing.save(String(version), account: account(uid: uid, clientId: clientId))
    }
}

/// Keychain-backed floor persistence: `kSecClassGenericPassword`, accessible only
/// `WhenUnlockedThisDeviceOnly`, never synced off device. A distinct Keychain
/// `service` from the agent-key pin keeps the two trust roots independent. A
/// present-but-undecodable value (not an integer) is surfaced as a read failure so
/// the caller fails closed.
struct HermesGatewayVersionFloorKeychainBacking: HermesGatewayPinBacking {
    static let service = "com.openburnbar.mobile.hermes-gateway-version-floor"

    func load(account: String) -> HermesGatewayPinLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return .absent
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8),
                  Int(value) != nil else {
                return .unreadable(errSecDecode)
            }
            return .found(value)
        default:
            return .unreadable(status)
        }
    }

    @discardableResult
    func save(_ value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(create as CFDictionary, nil)
        }
        return updateStatus
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
