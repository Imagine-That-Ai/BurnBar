import CryptoKit
import Foundation
import Security

/// # Phone-side iroh pairing admission (T-TRN-02 + T-TRN-05)
///
/// The iOS client dials the Mac at the `(nodeId, relayURL, directAddresses)`
/// carried in the signed `iroh_pairing` record. The Ed25519 signature
/// (`IrohPairingSignature`, verified in `IrohPairingPublisher.fetchAndVerify`)
/// proves the record was produced by the holder of the pairing key — but
/// transport *admission* (which NodeId is allowed, and which is the freshest
/// record) is still anchored in server-controlled state:
///
///  - **T-TRN-02** — admission of the controller/host NodeId is cloud-authoritative
///    (the `iroh_controllers` / pairing directory). A relay/backend in scope for
///    the E2EE threat model could publish a *validly signed* record (e.g. a stale
///    one it captured, or one for a reassigned NodeAddr) and steer the phone to a
///    different endpoint. The phone holds no local memory of which NodeId it
///    admitted. This store pins the first admitted NodeId per connection (TOFU,
///    Keychain, `WhenUnlockedThisDeviceOnly`), so a later record advertising a
///    *different* NodeId is refused until the operator deliberately re-pairs.
///
///  - **T-TRN-05** — a within-window REPLAY of an older signed record could steer
///    iOS to a NodeAddr that has since been reassigned. This store keeps a
///    monotonic high-water of the highest `publishedAtMillis` it has consumed for
///    a connection; a record at or below the high-water is refused as a replay.
///
/// Both protections mirror `IrohHostKeyPinStore` / `ControllerKeyPinStore`: the
/// only sanctioned rotation is an operator-initiated re-pair (which clears the
/// admission record), and every Keychain failure is fail-closed (refuse). The
/// pure decision lives over an injectable backing seam so every branch is
/// unit-testable on a CI runner with no Keychain entitlement.
struct IrohPairingAdmissionStore: Sendable {
    /// The persisted admission record for one connection: the pinned NodeId and
    /// the highest `publishedAtMillis` consumed so far.
    struct Admission: Codable, Equatable, Sendable {
        let nodeId: String
        let highWaterPublishedAtMillis: Int64
    }

    enum LoadResult: Equatable, Sendable {
        case found(Admission)
        case absent
        case unreadable(Int32)
    }

    /// Persistence seam. Production binds the Keychain; tests inject in-memory.
    protocol Backing: Sendable {
        func load(account: String) -> LoadResult
        @discardableResult func save(_ admission: Admission, account: String) -> Int32
        func delete(account: String)
    }

    /// Outcome of admitting a freshly-fetched, signature-verified record.
    enum AdmissionResult: Equatable, Sendable {
        /// No prior admission; this NodeId + timestamp was just pinned.
        case admittedFirstUse
        /// NodeId matches the pin and the timestamp advanced the high-water.
        case admitted
        /// The advertised NodeId differs from the pinned one — possible MITM /
        /// reassignment. Refuse; the operator must re-pair. Carries the pin.
        case nodeIdMismatch(pinned: String)
        /// `publishedAtMillis` is at or below the consumed high-water — a replay.
        case staleReplay(highWater: Int64, candidate: Int64)
        /// Keychain read/write failure — fail closed (refuse).
        case unknownKeychainError(status: Int)

        /// True only when the dial may proceed.
        var allowsDial: Bool {
            switch self {
            case .admittedFirstUse, .admitted: return true
            case .nodeIdMismatch, .staleReplay, .unknownKeychainError: return false
            }
        }
    }

    private let backing: Backing

    init(backing: Backing = IrohPairingAdmissionKeychainBacking()) {
        self.backing = backing
    }

    private func account(uid: String, connectionId: String) -> String {
        "\(uid)|\(connectionId)"
    }

    /// Admit a verified record for `connectionId`. Call AFTER the Ed25519
    /// signature has been verified — this layer adds NodeId pinning + replay
    /// protection on top of authenticity. Pure over the backing seam.
    func admit(
        nodeId rawNodeId: String,
        publishedAtMillis: Int64,
        uid: String,
        connectionId: String
    ) -> AdmissionResult {
        let nodeId = rawNodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeId.isEmpty else {
            return .nodeIdMismatch(pinned: pinnedNodeId(uid: uid, connectionId: connectionId) ?? "")
        }
        let acct = account(uid: uid, connectionId: connectionId)
        switch backing.load(account: acct) {
        case .found(let admission):
            guard admission.nodeId == nodeId else {
                return .nodeIdMismatch(pinned: admission.nodeId)
            }
            // T-TRN-05 — strictly-increasing high-water. Equal or older is a
            // replay of a record we already consumed.
            guard publishedAtMillis > admission.highWaterPublishedAtMillis else {
                return .staleReplay(highWater: admission.highWaterPublishedAtMillis, candidate: publishedAtMillis)
            }
            let updated = Admission(nodeId: nodeId, highWaterPublishedAtMillis: publishedAtMillis)
            let status = backing.save(updated, account: acct)
            guard status == errSecSuccessCompatAdmission else {
                return .unknownKeychainError(status: Int(status))
            }
            return .admitted
        case .absent:
            // First trust: pin the NodeId + seed the high-water. FAIL-CLOSED on a
            // write failure so a non-durable pin cannot reopen the first-pin
            // poisoning window on the next dial.
            let admission = Admission(nodeId: nodeId, highWaterPublishedAtMillis: publishedAtMillis)
            let status = backing.save(admission, account: acct)
            guard status == errSecSuccessCompatAdmission else {
                return .unknownKeychainError(status: Int(status))
            }
            return .admittedFirstUse
        case .unreadable(let status):
            return .unknownKeychainError(status: Int(status))
        }
    }

    /// The currently pinned NodeId for a connection, or `nil` if none / unreadable.
    func pinnedNodeId(uid: String, connectionId: String) -> String? {
        if case .found(let admission) = backing.load(account: account(uid: uid, connectionId: connectionId)) {
            return admission.nodeId
        }
        return nil
    }

    /// The consumed high-water for a connection, or `nil` if none.
    func highWaterPublishedAtMillis(uid: String, connectionId: String) -> Int64? {
        if case .found(let admission) = backing.load(account: account(uid: uid, connectionId: connectionId)) {
            return admission.highWaterPublishedAtMillis
        }
        return nil
    }

    /// Clear the admission so a deliberate operator-initiated re-pair establishes
    /// a fresh NodeId pin + high-water. The only sanctioned reset path.
    func clear(uid: String, connectionId: String) {
        backing.delete(account: account(uid: uid, connectionId: connectionId))
    }
}

/// `errSecSuccess` is only defined where Security is available.
let errSecSuccessCompatAdmission: Int32 = 0

/// Keychain-backed admission persistence: `kSecClassGenericPassword`, accessible
/// only `WhenUnlockedThisDeviceOnly`, never synced. A distinct `service` from the
/// host-key pin keeps the trust roots independent.
struct IrohPairingAdmissionKeychainBacking: IrohPairingAdmissionStore.Backing {
    static let service = "com.openburnbar.iroh.pairing-admission"

    func load(account: String) -> IrohPairingAdmissionStore.LoadResult {
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
                  let admission = try? JSONDecoder().decode(IrohPairingAdmissionStore.Admission.self, from: data) else {
                return .unreadable(errSecDecode)
            }
            return .found(admission)
        default:
            return .unreadable(status)
        }
    }

    @discardableResult
    func save(_ admission: IrohPairingAdmissionStore.Admission, account: String) -> Int32 {
        guard let data = try? JSONEncoder().encode(admission) else { return errSecParam }
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
