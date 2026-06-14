import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// # Iroh host-key pinning (T-TRN-01 / T-PTR-03 — transport-plane trust root, phone side)
///
/// **Threat closed.** A mobile client dials the user's Mac over iroh QUIC. The Mac
/// publishes its Ed25519 *host* pairing public key to a Firestore directory
/// (`users/{uid}/iroh_pairing_keys/{host}.publicKeyBase64`) and, until now, the
/// phone fetched it fresh from that directory on every cold session and trusted
/// whatever the server returned — keeping it only in an in-memory cache that did
/// not survive an app restart. A malicious/compromised relay or Firebase backend —
/// explicitly in scope for the E2EE threat model — could swap that key for an
/// attacker-held key and the phone would silently dial the attacker's QUIC
/// endpoint, hijacking / redirecting / downgrading the control channel. This is the
/// exact mirror of the control-plane gap that ``ControllerKeyPinStore`` closes on
/// the Mac side; the asymmetry (Mac pinned its controller key, phone did **not**
/// pin the host key) is what this store removes.
///
/// **Fix.** The phone becomes the authoritative root of trust for *which* host key
/// it will dial. On the first observation of the host key it is **pinned** to the
/// iOS Keychain (`WhenUnlockedThisDeviceOnly`, never synced). Every later fetch
/// compares the directory-advertised key against the pin:
///
/// - a *matching* key is admitted (the steady state);
/// - a *different* key is **refused** — a key change is a possible MITM and the
///   operator must deliberately re-pair (which clears the pin), exactly the
///   contract ``ControllerKeyPinStore`` / `HermesGatewayAgentKeyPinStore` use;
/// - the *first* key, when ``IrohHostKeyPinEnforcementFlag`` is enabled, requires
///   an out-of-band **safety-number** confirmation before it is trusted, closing
///   the first-contact TOFU window the same way Signal does.
///
/// **Rollout discipline.** The key-*change* rejection is always live (it only ever
/// refuses a key that actually differs from the one the phone first pinned, so it
/// cannot brick a stable pairing). First-use safety-number confirmation is
/// flag-gated (``IrohHostKeyPinEnforcementFlag``, default **off** until the
/// host-key compare UI is wired) so this change does not regress pairing on its
/// own; the ``PinResult/safetyCodeForConfirmation`` is already surfaced for that UI.
///
/// The store reuses the generic, already-unit-tested pin seams from
/// ``ControllerKeyPinStore`` (``ControllerKeyPinBacking``, ``ControllerPinRecord``,
/// ``InMemoryControllerKeyPinBacking``) so every branch is testable on a CI runner
/// with no Keychain entitlement; the shipping app always uses the Keychain.
public struct IrohHostKeyPinStore: Sendable {
    /// Outcome of checking a directory-advertised host key against the pin. Mirrors
    /// ``ControllerKeyPinStore/PinResult`` so callers share one admission contract.
    public enum PinResult: Equatable, Sendable {
        /// Advertised key matches a pin the operator already confirmed out-of-band.
        case matchesConfirmedPin
        /// Advertised key matches the pin, but it has not been confirmed yet.
        case matchesPendingConfirmation(safetyCode: String?)
        /// No pin existed; the advertised key was just pinned (unconfirmed).
        case pinnedFirstUse(safetyCode: String?)
        /// Advertised key differs from the pin — a possible MITM / host-key swap.
        /// **Always refuse**; the operator must re-pair to rotate.
        case mismatch(pinnedSafetyCode: String?)
        /// Advertised key is empty / not base64 / not a 32-byte Ed25519 key.
        case malformedAdvertisedKey
        /// The Keychain could not be read, or the first pin could not be written.
        /// Fail-closed (refuse) rather than trust a phantom pin.
        case unknownKeychainError(status: Int)

        /// Whether admission may proceed given the safety-number gate state.
        public func admits(requireConfirmation: Bool) -> Bool {
            switch self {
            case .matchesConfirmedPin:
                return true
            case .matchesPendingConfirmation, .pinnedFirstUse:
                return !requireConfirmation
            case .mismatch, .malformedAdvertisedKey, .unknownKeychainError:
                return false
            }
        }

        /// The safety code to present for confirmation, if this result is one the
        /// operator can resolve by comparing codes.
        public var safetyCodeForConfirmation: String? {
            switch self {
            case .matchesPendingConfirmation(let code), .pinnedFirstUse(let code):
                return code
            case .matchesConfirmedPin, .mismatch, .malformedAdvertisedKey, .unknownKeychainError:
                return nil
            }
        }

        /// `true` when this result represents a refused admission (used by callers
        /// to map to a thrown transport error / audit event).
        public var isRefusal: Bool {
            switch self {
            case .mismatch, .malformedAdvertisedKey, .unknownKeychainError:
                return true
            case .matchesConfirmedPin, .matchesPendingConfirmation, .pinnedFirstUse:
                return false
            }
        }
    }

    private let backing: ControllerKeyPinBacking
    /// Base64 of this device's own iroh peer / pairing public key, folded into the
    /// safety code so a relay that swaps *either* the host key or this device's key
    /// changes the displayed code (mutual binding). `nil` only in tests that do not
    /// exercise the safety-code display.
    private let localPublicKeyBase64: String?

    public init(
        backing: ControllerKeyPinBacking = IrohHostKeyPinStore.defaultBacking(),
        localPublicKeyBase64: String? = nil
    ) {
        self.backing = backing
        self.localPublicKeyBase64 = localPublicKeyBase64
    }

    /// Account scope is `uid|roleId` so a host key pinned for one account never
    /// matches a different signed-in user, and a future multi-role directory
    /// (e.g. a second Mac) pins independently.
    private func account(uid: String, roleId: String) -> String {
        "\(uid)|\(roleId)"
    }

    /// Verify (and on first use, pin) the host signing key advertised for `roleId`.
    /// Pure over the backing seam; safe to call on every dial.
    public func verifyOrPin(advertisedKeyBase64 advertised: String, uid: String, roleId: String) -> PinResult {
        guard let normalized = ControllerKeyPinStore.normalizedEd25519KeyBase64(advertised) else {
            return .malformedAdvertisedKey
        }
        let acct = account(uid: uid, roleId: roleId)
        switch backing.load(account: acct) {
        case .found(let record):
            if record.keyBase64 == normalized {
                return record.confirmed
                    ? .matchesConfirmedPin
                    : .matchesPendingConfirmation(safetyCode: safetyCode(forKeyBase64: normalized))
            }
            return .mismatch(pinnedSafetyCode: safetyCode(forKeyBase64: record.keyBase64))
        case .absent:
            // First trust: pin it, FAIL-CLOSED on a write failure. A silently
            // unpersisted pin would let the next fetch re-pin from the
            // relay-advertised key (reopening the first-pin poisoning window).
            let record = ControllerPinRecord(
                keyBase64: normalized,
                confirmed: false,
                pinnedAtEpoch: Date().timeIntervalSince1970
            )
            let status = backing.save(record, account: acct)
            guard status == errSecSuccessCompat else {
                return .unknownKeychainError(status: Int(status))
            }
            return .pinnedFirstUse(safetyCode: safetyCode(forKeyBase64: normalized))
        case .unreadable(let status):
            return .unknownKeychainError(status: Int(status))
        }
    }

    /// Mark the host-key pin for `roleId` as confirmed after the operator compared
    /// the safety number on both devices. Idempotent.
    @discardableResult
    public func confirm(advertisedKeyBase64 advertised: String, uid: String, roleId: String) -> Bool {
        guard let normalized = ControllerKeyPinStore.normalizedEd25519KeyBase64(advertised) else { return false }
        let acct = account(uid: uid, roleId: roleId)
        guard case .found(let record) = backing.load(account: acct), record.keyBase64 == normalized else {
            return false
        }
        if record.confirmed { return true }
        let confirmed = ControllerPinRecord(
            keyBase64: record.keyBase64,
            confirmed: true,
            pinnedAtEpoch: record.pinnedAtEpoch
        )
        return backing.save(confirmed, account: acct) == errSecSuccessCompat
    }

    /// Clear the pin for `roleId` so a deliberate operator-initiated re-pair can
    /// establish a new host key. The only sanctioned rotation path — no
    /// relay-supplied update can change a pin in place.
    public func clearPin(uid: String, roleId: String) {
        backing.delete(account: account(uid: uid, roleId: roleId))
    }

    /// The currently pinned host-key record, or `nil` if none / unreadable.
    public func pinnedRecord(uid: String, roleId: String) -> ControllerPinRecord? {
        if case .found(let record) = backing.load(account: account(uid: uid, roleId: roleId)) {
            return record
        }
        return nil
    }

    private func safetyCode(forKeyBase64 hostKeyBase64: String) -> String? {
        guard let localPublicKeyBase64 else { return nil }
        // Order-independent mutual binding of the host key and this device's key.
        return ControllerKeySafetyCode.format(publicKeysBase64: [hostKeyBase64, localPublicKeyBase64])
    }
}

/// Rollout flag for the stricter first-use safety-number confirmation of the host
/// key, mirroring ``ControllerKeyPinEnforcementFlag``. Default **off**: the
/// always-live key-*change* rejection already closes the post-pairing
/// cloud-substitution attack (T-TRN-01); flipping this on additionally closes the
/// first-contact TOFU window and requires the host-key safety-number compare UI to
/// be wired so a first-use fetch can surface ``IrohHostKeyPinStore/PinResult/safetyCodeForConfirmation``.
public enum IrohHostKeyPinEnforcementFlag {
    public static let userDefaultsKey = "openburnbar.irohHostKeyPin.safetyConfirmation.enabled"

    public nonisolated(unsafe) static var defaultEnabled = false

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: userDefaultsKey) != nil {
            return defaults.bool(forKey: userDefaultsKey)
        }
        return defaultEnabled
    }
}

#if canImport(Security)
/// Keychain-backed host-key pin persistence: `kSecClassGenericPassword`, accessible
/// only `WhenUnlockedThisDeviceOnly`, never synced off device. Distinct Keychain
/// `service` from the controller-key pin so the two trust roots never collide.
public struct IrohHostKeyKeychainPinBacking: ControllerKeyPinBacking {
    public static let service = "com.openburnbar.iroh.host-key-pin"

    public init() {}

    public func load(account: String) -> ControllerKeyPinLoad {
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
                  let record = try? JSONDecoder().decode(ControllerPinRecord.self, from: data) else {
                return .unreadable(errSecDecode)
            }
            return .found(record)
        default:
            return .unreadable(status)
        }
    }

    @discardableResult
    public func save(_ record: ControllerPinRecord, account: String) -> Int32 {
        guard let data = try? JSONEncoder().encode(record) else { return errSecParam }
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

    public func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension IrohHostKeyPinStore {
    /// Production default: the device Keychain.
    public static func defaultBacking() -> ControllerKeyPinBacking { IrohHostKeyKeychainPinBacking() }
}
#else
extension IrohHostKeyPinStore {
    /// On platforms without the Security framework (Linux CI) the default backing
    /// is in-memory; the shipping iOS app always resolves to the Keychain.
    public static func defaultBacking() -> ControllerKeyPinBacking { InMemoryControllerKeyPinBacking() }
}
#endif
