import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// # Controller key pinning (F1 keystone — control-plane trust root)
///
/// **Threat closed.** A remote phone "controller" drives the Mac by signing
/// `control.input` intents with an Ed25519 key. Today the Mac fetches that
/// signing key from a Firestore directory
/// (`users/{uid}/iroh_pairing/{connId}/controllers/{peerNodeId}.publicKeyBase64`)
/// and trusts it on every fetch as long as the named escrow device is
/// `trusted`. A malicious/compromised relay or Firestore backend — explicitly
/// in scope for the E2EE threat model — can swap that key for an attacker-held
/// key and the Mac silently re-admits it, yielding unattended keystroke/mouse
/// injection (→ RCE) and screen capture. The end-to-end libsignal layer does
/// **not** stop this, because the control-plane authorization key is anchored
/// in server-controlled state, not in the verified end-to-end identity.
///
/// **Fix.** The Mac becomes the authoritative root of trust for *which* key may
/// drive it. On the first observation of a controller's signing key it is
/// **pinned** to the Mac Keychain (`WhenUnlockedThisDeviceOnly`, never synced).
/// Every later admission compares the directory-advertised key against the pin:
///
/// - a *matching* key is admitted (the steady state);
/// - a *different* key is **refused** — a key change is a possible MITM and the
///   operator must deliberately re-pair (which clears the pin), exactly the
///   contract `HermesGatewayAgentKeyPinStore` already uses for the Hermes lane;
/// - the *first* key, when ``ControllerKeyPinEnforcementFlag`` is enabled,
///   requires an out-of-band **safety-number** confirmation before it is
///   trusted — the operator compares the code shown on the Mac with the one on
///   the phone, closing the first-contact TOFU window the same way Signal does.
///
/// **Rollout discipline.** The key-*change* rejection is always live (it only
/// ever refuses a key that actually differs from what the operator first saw,
/// so it cannot brick a stable pairing). The stricter first-use safety-number
/// confirmation is gated behind ``ControllerKeyPinEnforcementFlag`` (default
/// **off**) so it activates only once the cross-platform safety-number UI ships
/// — mirroring ``EscrowDeviceTrustSafetyCheckFlag`` and the server-side
/// `ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED`.
///
/// The pure decision lives in ``ControllerKeyPinStore/verifyOrPin(advertisedKeyBase64:uid:peerNodeId:)``
/// over an injectable ``ControllerKeyPinBacking`` seam, so every branch is unit
/// testable with an in-memory backing on a CI runner that has no Keychain
/// entitlement — the shipping app always uses the Keychain.

/// Result of a Keychain read behind ``ControllerKeyPinBacking``.
public enum ControllerKeyPinLoad: Equatable, Sendable {
    /// A pinned record was found and decoded.
    case found(ControllerPinRecord)
    /// No pin exists for this account (genuine first contact).
    case absent
    /// The item exists but could not be read/decoded — a tamper/corruption
    /// signal the caller treats as fail-closed. Carries the `OSStatus` (or a
    /// synthetic code for decode failures).
    case unreadable(Int32)
}

/// Persistence seam behind ``ControllerKeyPinStore``. Production binds this to
/// the Keychain (``ControllerKeyKeychainPinBacking``); tests inject an in-memory
/// backing so the fail-closed pin logic is verifiable on unsigned simulators /
/// CI runners where the Keychain returns `errSecMissingEntitlement` (-34018).
/// The seam never weakens production — the shipping app always uses the Keychain.
public protocol ControllerKeyPinBacking: Sendable {
    func load(account: String) -> ControllerKeyPinLoad
    @discardableResult func save(_ record: ControllerPinRecord, account: String) -> Int32
    func delete(account: String)
}

/// The durable pin for one controller: the signing key the operator approved,
/// and whether that approval has been confirmed out-of-band via a safety number.
public struct ControllerPinRecord: Codable, Equatable, Sendable {
    /// Base64 of the controller's Ed25519 signing public key (32 raw bytes).
    public let keyBase64: String
    /// `true` once the operator compared the safety number on both devices.
    /// `false` for a freshly auto-pinned key awaiting confirmation.
    public let confirmed: Bool
    /// Unix epoch seconds the key was first pinned (diagnostics / audit only).
    public let pinnedAtEpoch: Double

    public init(keyBase64: String, confirmed: Bool, pinnedAtEpoch: Double) {
        self.keyBase64 = keyBase64
        self.confirmed = confirmed
        self.pinnedAtEpoch = pinnedAtEpoch
    }
}

/// Rollout flag for the stricter first-use safety-number confirmation, mirroring
/// ``EscrowDeviceTrustSafetyCheckFlag``. Default **off**: the always-on key-change
/// rejection ships immediately; the first-use confirmation gate turns on only once
/// the Mac + phone safety-number UI is in place. A `UserDefaults` override lets QA /
/// UI tests exercise the gated path before it is the default.
public enum ControllerKeyPinEnforcementFlag {
    public static let userDefaultsKey = "openburnbar.controllerKeyPin.safetyConfirmation.enabled"

    public nonisolated(unsafe) static var defaultEnabled = false

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: userDefaultsKey) != nil {
            return defaults.bool(forKey: userDefaultsKey)
        }
        return defaultEnabled
    }
}

/// Mac-Keychain trust-on-first-use pin for each remote controller's Ed25519
/// signing key. See the file header for the threat model and rollout posture.
public struct ControllerKeyPinStore: Sendable {
    /// Outcome of checking a directory-advertised controller key against the pin.
    public enum PinResult: Equatable, Sendable {
        /// The advertised key matches a pin the operator already confirmed
        /// out-of-band. Always safe to admit.
        case matchesConfirmedPin
        /// The advertised key matches the pin, but the pin has not yet been
        /// confirmed out-of-band. Safe to admit only when the safety-number gate
        /// is disabled; otherwise the caller must surface the `safetyCode` for
        /// confirmation. Carries the code so the UI need not recompute it.
        case matchesPendingConfirmation(safetyCode: String?)
        /// No pin existed; the advertised key was just pinned (unconfirmed).
        /// Same admission rule as ``matchesPendingConfirmation``.
        case pinnedFirstUse(safetyCode: String?)
        /// The advertised key differs from the pin — a possible MITM / key swap.
        /// **Always refuse**; the operator must re-pair to rotate. Carries the
        /// pinned key's safety code for the "this device changed" diagnostics.
        case mismatch(pinnedSafetyCode: String?)
        /// The advertised key is empty / not valid base64 / not a 32-byte
        /// Ed25519 key. Refuse.
        case malformedAdvertisedKey
        /// The Keychain could not be read or the first pin could not be written.
        /// Fail-closed (refuse) rather than trust a phantom pin.
        case unknownKeychainError(status: Int)

        /// Whether admission may proceed given the safety-number gate state.
        ///
        /// - Parameter requireConfirmation: pass
        ///   ``ControllerKeyPinEnforcementFlag/isEnabled(defaults:)``. When `true`,
        ///   only a confirmed pin admits; an unconfirmed/first-use key must go
        ///   through the safety-number confirmation flow first.
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
    }

    private let backing: ControllerKeyPinBacking
    /// Base64 of the Mac host's own pairing public key, folded into the safety
    /// code so a relay that swaps *either* the controller key or the host key
    /// changes the displayed code (mutual binding, like the Hermes safety code).
    /// `nil` only in unit tests that do not exercise the safety-code display.
    private let hostPublicKeyBase64: String?

    public init(
        backing: ControllerKeyPinBacking = ControllerKeyPinStore.defaultBacking(),
        hostPublicKeyBase64: String? = nil
    ) {
        self.backing = backing
        self.hostPublicKeyBase64 = hostPublicKeyBase64
    }

    /// Account scope is `uid|peerNodeId` so a reused `peerNodeId` across accounts
    /// (or a stale pin from a different signed-in user) never matches.
    private func account(uid: String, peerNodeId: String) -> String {
        "\(uid)|\(peerNodeId)"
    }

    /// Verify (and on first use, pin) the controller signing key advertised for a
    /// `peerNodeId`. Pure over the backing seam; safe to call on every
    /// `control.classify`.
    public func verifyOrPin(advertisedKeyBase64 advertised: String, uid: String, peerNodeId: String) -> PinResult {
        guard let normalized = Self.normalizedEd25519KeyBase64(advertised) else {
            return .malformedAdvertisedKey
        }
        let acct = account(uid: uid, peerNodeId: peerNodeId)
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
            // unpersisted pin would let the next admission re-pin from the
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

    /// Mark the pin for `peerNodeId` as confirmed after the operator compared the
    /// safety number on both devices. Idempotent. Returns `false` if there is no
    /// pin to confirm or the advertised key no longer matches the pin (in which
    /// case the caller must re-run ``verifyOrPin(advertisedKeyBase64:uid:peerNodeId:)``).
    @discardableResult
    public func confirm(advertisedKeyBase64 advertised: String, uid: String, peerNodeId: String) -> Bool {
        guard let normalized = Self.normalizedEd25519KeyBase64(advertised) else { return false }
        let acct = account(uid: uid, peerNodeId: peerNodeId)
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

    /// Clear the pin for `peerNodeId` so a deliberate operator-initiated re-pair
    /// can establish a new key. This is the only sanctioned rotation path — no
    /// relay-supplied update, signed or unsigned, can change a pin in place.
    public func clearPin(uid: String, peerNodeId: String) {
        backing.delete(account: account(uid: uid, peerNodeId: peerNodeId))
    }

    /// The currently pinned record for a controller, or `nil` if none / unreadable.
    public func pinnedRecord(uid: String, peerNodeId: String) -> ControllerPinRecord? {
        if case .found(let record) = backing.load(account: account(uid: uid, peerNodeId: peerNodeId)) {
            return record
        }
        return nil
    }

    /// Safety code binding the controller key to the Mac host pairing key, or
    /// `nil` when the host key is unavailable (tests) or either key is malformed.
    private func safetyCode(forKeyBase64 controllerKeyBase64: String) -> String? {
        guard let hostPublicKeyBase64 else { return nil }
        return ControllerKeySafetyCode.format(
            controllerKeyBase64: controllerKeyBase64,
            hostKeyBase64: hostPublicKeyBase64
        )
    }

    /// Validate that `advertised` decodes to a genuine 32-byte Ed25519 public key
    /// and return its canonical base64, or `nil`. Importing through CryptoKit
    /// rejects wrong-length / off-curve keys so a malformed key fails closed
    /// rather than being pinned.
    static func normalizedEd25519KeyBase64(_ advertised: String) -> String? {
        let trimmed = advertised.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let raw = Data(base64Encoded: trimmed),
              raw.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else {
            return nil
        }
        return raw.base64EncodedString()
    }
}

/// `errSecSuccess` is only defined when the Security framework is available; on
/// other platforms (Linux CI) the in-memory backing returns 0 for success.
let errSecSuccessCompat: Int32 = 0

#if canImport(Security)
/// Keychain-backed pin persistence: `kSecClassGenericPassword`, accessible only
/// `WhenUnlockedThisDeviceOnly`, never synced off device.
public struct ControllerKeyKeychainPinBacking: ControllerKeyPinBacking {
    public static let service = "com.openburnbar.computeruse.controller-key-pin"

    public init() {}

    public func load(account: String) -> ControllerKeyPinLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return .absent
        case errSecSuccess:
            guard let data = item as? Data,
                  let record = try? JSONDecoder().decode(ControllerPinRecord.self, from: data) else {
                // Present-but-undecodable is a tamper/corruption signal → fail closed.
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
            kSecAttrAccount as String: account,
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
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension ControllerKeyPinStore {
    /// Production default: the device Keychain.
    public static func defaultBacking() -> ControllerKeyPinBacking { ControllerKeyKeychainPinBacking() }
}
#else
extension ControllerKeyPinStore {
    /// On platforms without the Security framework (Linux CI) the default backing
    /// is in-memory; the shipping macOS app always resolves to the Keychain.
    public static func defaultBacking() -> ControllerKeyPinBacking { InMemoryControllerKeyPinBacking() }
}
#endif

/// In-memory backing for tests and non-Keychain platforms. Thread-safe.
public final class InMemoryControllerKeyPinBacking: ControllerKeyPinBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: ControllerPinRecord] = [:]
    /// When set, every `load` returns `.unreadable(this)` to drive the
    /// fail-closed Keychain-error branch in tests.
    private var forcedReadError: Int32?
    /// When set, every `save` returns this non-success status to drive the
    /// fail-closed write-failure branch in tests.
    private var forcedWriteError: Int32?

    public init() {}

    public func failReads(with status: Int32) { lock.lock(); forcedReadError = status; lock.unlock() }
    public func failWrites(with status: Int32) { lock.lock(); forcedWriteError = status; lock.unlock() }

    public func load(account: String) -> ControllerKeyPinLoad {
        lock.lock(); defer { lock.unlock() }
        if let forcedReadError { return .unreadable(forcedReadError) }
        if let record = store[account] { return .found(record) }
        return .absent
    }

    @discardableResult
    public func save(_ record: ControllerPinRecord, account: String) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if let forcedWriteError { return forcedWriteError }
        store[account] = record
        return errSecSuccessCompat
    }

    public func delete(account: String) {
        lock.lock(); defer { lock.unlock() }
        store[account] = nil
    }
}
