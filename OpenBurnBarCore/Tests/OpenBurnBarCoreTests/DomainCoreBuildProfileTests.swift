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
        XCTAssertNil(profile.candidateIdentity)
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
        XCTAssertEqual(profile.candidateIdentity?.abiVersion, 3)
    }

    func testSignedRollbackProfilePermanentlySelectsLegacyAcrossEveryDomain() {
        let environment = Dictionary(
            uniqueKeysWithValues: DomainCoreBuildDomain.allCases.map { domain in
                let key = switch domain {
                case .quota: "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE"
                case .cloudVault: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE"
                case .cloudVaultRewrap: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE"
                case .cloudVaultSearch: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE"
                case .hermes: "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE"
                case .pricing: "OPENBURNBAR_DOMAIN_CORE_PRICING_MODE"
                }
                return (key, "rust")
            }
        )
        let profile = DomainCoreBuildProfileResolver.current(
            environment: environment,
            info: signedInfo(name: "public-production-rollback", distribution: "public", channel: "", evidence: false)
        )

        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(profile.name, "public-production-rollback")
        XCTAssertTrue(profile.modes.values.allSatisfy { $0 == .legacy })
        XCTAssertEqual(profile.candidateIdentity?.candidateCommit, String(repeating: "a", count: 40))
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

    func testSignedProfilesRequireACompleteCanonicalCandidateIdentity() {
        let malformed: [[String: Any]] = [
            signedInternalInfo()
                .removing("OpenBurnBarDomainCoreCandidateCommit"),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreCandidateCommit", with: String(repeating: "A", count: 40)),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreExpectedVersion", with: "01.2.3"),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreExpectedVersion", with: "1.2.3-01"),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreExpectedVersion", with: "1.2.3\n"),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreExpectedVersion", with: "1.2.3-" + String(repeating: "a", count: 59)),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreExpectedABIVersion", with: "03"),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreExpectedABIVersion", with: true),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreExpectedABIVersion", with: 4_294_967_296),
            signedInternalInfo()
                .replacing("OpenBurnBarDomainCoreExpectedSourceSHA256", with: String(repeating: "B", count: 64)),
            signedInfo(name: "public-production", distribution: "public", channel: "", evidence: false)
                .removing("OpenBurnBarDomainCoreCandidateCommit")
                .removing("OpenBurnBarDomainCoreExpectedVersion")
                .removing("OpenBurnBarDomainCoreExpectedABIVersion")
                .removing("OpenBurnBarDomainCoreExpectedSourceSHA256")
        ]

        for info in malformed {
            let profile = DomainCoreBuildProfileResolver.current(info: info)
            XCTAssertFalse(profile.isValid)
            XCTAssertFalse(profile.evidenceEnabled)
            XCTAssertNil(profile.candidateIdentity)
            XCTAssertTrue(profile.modes.values.allSatisfy { $0 == .legacy })
        }
    }

    func testDeveloperCandidateIdentityIsOptionalButMustBeCanonicalWhenPresent() {
        var validInfo = candidateInfo()
        validInfo["OpenBurnBarDomainCoreBuildAuthority"] = "development"
        let valid = DomainCoreBuildProfileResolver.current(info: validInfo)
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.candidateIdentity?.candidateCommit, String(repeating: "a", count: 40))

        validInfo.removeValue(forKey: "OpenBurnBarDomainCoreExpectedVersion")
        let partial = DomainCoreBuildProfileResolver.current(info: validInfo)
        XCTAssertFalse(partial.isValid)
        XCTAssertNil(partial.candidateIdentity)
    }

    func testUnknownAuthorityFailsClosedAndIgnoresEnvironment() {
        let profile = DomainCoreBuildProfileResolver.current(
            environment: ["OPENBURNBAR_DOMAIN_CORE_HERMES_MODE": "rust"],
            info: ["OpenBurnBarDomainCoreBuildAuthority": "sigend"]
        )

        XCTAssertFalse(profile.isValid)
        XCTAssertEqual(profile.artifactAuthority, "sigend")
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
            "OpenBurnBarDomainCoreEvidenceEnabled": evidence
        ]
        info.merge(candidateInfo()) { _, candidateValue in candidateValue }
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

    private func candidateInfo() -> [String: Any] {
        [
            "OpenBurnBarDomainCoreCandidateCommit": String(repeating: "a", count: 40),
            "OpenBurnBarDomainCoreExpectedVersion": "0.3.0",
            "OpenBurnBarDomainCoreExpectedABIVersion": 3,
            "OpenBurnBarDomainCoreExpectedSourceSHA256": String(repeating: "b", count: 64)
        ]
    }

    private func signedInternalInfo() -> [String: Any] {
        var info = signedInfo(name: "internal", distribution: "internal", channel: "internal", evidence: true)
        info["OpenBurnBarDomainCoreModeQuota"] = "shadow"
        return info
    }
}

private extension Dictionary where Key == String, Value == Any {
    func removing(_ key: String) -> Self {
        var copy = self
        copy.removeValue(forKey: key)
        return copy
    }

    func replacing(_ key: String, with value: Any) -> Self {
        var copy = self
        copy[key] = value
        return copy
    }
}
