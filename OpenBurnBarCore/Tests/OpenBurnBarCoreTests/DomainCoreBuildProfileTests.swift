import XCTest
@testable import OpenBurnBarCore

final class DomainCoreBuildProfileTests: XCTestCase {
    func testDevelopmentBuildAllowsExplicitModeOverrideButNeverEvidence() {
        let profile = DomainCoreBuildProfileResolver.current(
            environment: ["OPENBURNBAR_DOMAIN_CORE_HERMES_MODE": "rust"],
            info: [:]
        )
        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(profile.artifactAuthority, "development")
        XCTAssertEqual(profile.modes[.hermes], .rust)
        XCTAssertNil(DomainCoreBuildProfileResolver.evidenceChannel(environment: [:], info: [:]))
    }

    func testSignedPublicProfileIgnoresEnvironmentOverrides() {
        let profile = DomainCoreBuildProfileResolver.current(
            environment: ["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE": "shadow"],
            info: signedInfo(name: "public-production", distribution: "public", channel: "", evidence: false)
        )
        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(profile.modes[.quota], .legacy)
        XCTAssertFalse(profile.evidenceEnabled)
        XCTAssertNil(profile.rolloutChannel)
    }

    func testSignedInternalAndBetaProfilesExposeOnlyTheirEmbeddedChannel() {
        for channel in ["internal", "beta"] {
            var info = signedInfo(name: channel, distribution: channel, channel: channel, evidence: true)
            info["OpenBurnBarDomainCoreModeQuota"] = "shadow"
            XCTAssertEqual(
                DomainCoreBuildProfileResolver.evidenceChannel(
                    environment: ["OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL": channel == "internal" ? "beta" : "internal"],
                    info: info
                ),
                channel
            )
        }
    }

    func testMalformedSignedMetadataFailsClosedAcrossEveryDomain() {
        var info = signedInfo(name: "public-production", distribution: "public", channel: "internal", evidence: true)
        info["OpenBurnBarDomainCoreModeHermes"] = "shadow"
        let profile = DomainCoreBuildProfileResolver.current(
            environment: ["OPENBURNBAR_DOMAIN_CORE_HERMES_MODE": "rust"],
            info: info
        )
        XCTAssertFalse(profile.isValid)
        XCTAssertFalse(profile.evidenceEnabled)
        XCTAssertNil(profile.rolloutChannel)
        XCTAssertTrue(profile.modes.values.allSatisfy { $0 == .legacy })
    }

    private func signedInfo(
        name: String,
        distribution: String,
        channel: String,
        evidence: Bool
    ) -> [String: Any] {
        var info: [String: Any] = [
            "OpenBurnBarDomainCoreBuildAuthority": "signed",
            "OpenBurnBarDomainCoreBuildProfile": name,
            "OpenBurnBarDomainCoreDistribution": distribution,
            "OpenBurnBarDomainCoreRolloutChannel": channel,
            "OpenBurnBarDomainCoreEvidenceEnabled": evidence,
        ]
        for domain in DomainCoreBuildDomain.allCases {
            let key = switch domain {
            case .quota: "OpenBurnBarDomainCoreModeQuota"
            case .cloudVault: "OpenBurnBarDomainCoreModeCloudVault"
            case .cloudVaultRewrap: "OpenBurnBarDomainCoreModeCloudVaultRewrap"
            case .cloudVaultSearch: "OpenBurnBarDomainCoreModeCloudVaultSearch"
            case .hermes: "OpenBurnBarDomainCoreModeHermes"
            case .pricing: "OpenBurnBarDomainCoreModePricing"
            }
            info[key] = "legacy"
        }
        return info
    }
}
