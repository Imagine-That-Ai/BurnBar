import XCTest
@testable import OpenBurnBarMobile

/// T-IOS-09 — the rollout gate that decides whether the at-rest escrow private
/// key is biometry-gated (`kSecAccessControl .biometryCurrentSet`). Pure decision
/// over an injected `UserDefaults`, so it is verifiable without a Keychain or a
/// device with biometry enrolled.
final class EscrowKeychainBiometryPolicyTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "EscrowKeychainBiometryPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultIsOffSoSilentVaultUnwrapIsNotBroken() {
        let defaults = makeDefaults()
        XCTAssertFalse(
            EscrowKeychainBiometryPolicy.isEnabled(defaults: defaults),
            "Default must be off until the vault flow presents an LAContext, so background unwrap never trips a biometric prompt."
        )
    }

    func testOverrideEnablesGate() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: EscrowKeychainBiometryPolicy.userDefaultsKey)
        XCTAssertTrue(EscrowKeychainBiometryPolicy.isEnabled(defaults: defaults))
    }

    func testOverrideCanForceDisable() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: EscrowKeychainBiometryPolicy.userDefaultsKey)
        XCTAssertFalse(EscrowKeychainBiometryPolicy.isEnabled(defaults: defaults))
    }
}
