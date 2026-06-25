import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias NoticeKind = ConnectionsSettingsView.ExternalOAuthCredentialNotice.Kind
private typealias SourceKind = OpenBurnBar.ProviderQuotaSourceKind
private typealias Confidence = OpenBurnBar.ProviderQuotaConfidence

/// Pins the rule that fixed the "refresh nag" bug: a credential that is
/// genuinely present is never reported as **"Credential not found"**, even when
/// the provider returns no quota buckets. Isolated Claude OAuth (Max/Pro)
/// profiles sign in successfully while Anthropic withholds quota windows — that
/// is a `.quotaUnavailable` state, not a missing credential.
@MainActor
final class ExternalCredentialNoticeClassifierTests: XCTestCase {

    private func classify(
        isDisabled: Bool = false,
        isCurrentLogin: Bool = false,
        hasQuotaWindows: Bool = false,
        authConnected: Bool? = nil,
        snapshotSource: SourceKind? = nil,
        snapshotConfidence: Confidence? = nil
    ) -> NoticeKind? {
        ConnectionsSettingsView.classifyExternalCredentialNotice(
            isDisabled: isDisabled,
            isCurrentLogin: isCurrentLogin,
            hasQuotaWindows: hasQuotaWindows,
            authConnected: authConnected,
            snapshotSource: snapshotSource,
            snapshotConfidence: snapshotConfidence
        )
    }

    // MARK: - The regression

    /// The exact shape from the bug report: an isolated Claude Max profile is
    /// signed in (`authConnected == true`) but Anthropic returned no buckets, so
    /// the adapter emits an `officialAPI` / `.unavailable` snapshot. This must
    /// read as quota-unavailable, never "Credential not found".
    func test_connectedCredential_withWithheldQuota_isQuotaUnavailable_notMissing() {
        XCTAssertEqual(
            classify(
                authConnected: true,
                snapshotSource: .officialAPI,
                snapshotConfidence: .unavailable
            ),
            .quotaUnavailable
        )
    }

    /// An `officialAPI`-sourced snapshot proves the adapter loaded this
    /// account's stored credential, so the credential is present even when local
    /// auth discovery produced nothing (`authConnected == nil`).
    func test_officialAPISnapshot_provesCredential_evenWithoutAuthDiscovery() {
        XCTAssertEqual(
            classify(
                authConnected: nil,
                snapshotSource: .officialAPI,
                snapshotConfidence: .unavailable
            ),
            .quotaUnavailable
        )
    }

    /// After a successful refresh, auth discovery should find the credential and
    /// no snapshot may exist yet — still "present", so quota-unavailable.
    func test_connectedNoSnapshotYet_isQuotaUnavailable() {
        XCTAssertEqual(classify(authConnected: true), .quotaUnavailable)
    }

    // MARK: - Genuinely missing credentials still warn

    func test_disconnectedAuth_isCredentialMissing() {
        XCTAssertEqual(classify(authConnected: false), .credentialMissing)
    }

    /// Auth discovery is authoritative: a disconnected credential is "missing"
    /// even if a stale non-`unavailable` snapshot is lying around.
    func test_disconnectedAuth_overridesSnapshot() {
        XCTAssertEqual(
            classify(
                authConnected: false,
                snapshotSource: .officialAPI,
                snapshotConfidence: .exact
            ),
            .credentialMissing
        )
    }

    /// No auth signal and an `.unavailable`-sourced snapshot (the adapter could
    /// not load any credential for this scope) is genuinely missing.
    func test_noSignal_unavailableSnapshot_isCredentialMissing() {
        XCTAssertEqual(
            classify(
                authConnected: nil,
                snapshotSource: .unavailable,
                snapshotConfidence: .unavailable
            ),
            .credentialMissing
        )
    }

    /// Nothing known at all about a saved (non-current-login) profile: missing.
    func test_noSignalAtAll_savedProfile_isCredentialMissing() {
        XCTAssertEqual(classify(), .credentialMissing)
    }

    // MARK: - Usable snapshots

    /// A usable snapshot (real source + confidence) without rendered windows
    /// still proves the credential and reads as a quota gap, not missing.
    func test_usableSnapshotWithoutWindows_isQuotaUnavailable() {
        XCTAssertEqual(
            classify(
                authConnected: nil,
                snapshotSource: .localCLI,
                snapshotConfidence: .exact
            ),
            .quotaUnavailable
        )
    }

    // MARK: - Quiet states

    func test_disabled_isSilent() {
        XCTAssertNil(classify(isDisabled: true, authConnected: false))
    }

    func test_hasQuotaWindows_isSilent() {
        XCTAssertNil(classify(hasQuotaWindows: true, authConnected: false))
    }

    // MARK: - Current-login edge cases

    /// The default local CLI login shouldn't nag when discovery is inconclusive
    /// and no snapshot exists.
    func test_currentLogin_connectedNoSnapshot_isSilent() {
        XCTAssertNil(classify(isCurrentLogin: true, authConnected: true))
    }

    func test_currentLogin_noSignal_isSilent() {
        XCTAssertNil(classify(isCurrentLogin: true, authConnected: nil))
    }

    func test_currentLogin_disconnected_isCredentialMissing() {
        XCTAssertEqual(classify(isCurrentLogin: true, authConnected: false), .credentialMissing)
    }

    /// A current login that is signed in but whose quota is withheld should
    /// surface the quota gap, not a false "missing".
    func test_currentLogin_withWithheldQuota_isQuotaUnavailable() {
        XCTAssertEqual(
            classify(
                isCurrentLogin: true,
                authConnected: true,
                snapshotSource: .officialAPI,
                snapshotConfidence: .unavailable
            ),
            .quotaUnavailable
        )
    }
}
