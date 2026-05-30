import XCTest
@testable import OpenBurnBarCore

/// Release-lane smoke: Developer-ID entitlements intentionally omit profiled capabilities.
final class DeveloperIDReleaseEntitlementsSmokeTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func test_releaseEntitlements_matchExpectedGracefulDegradationMatrix() throws {
        let url = repoRoot.appendingPathComponent("AgentLens/Resources/OpenBurnBarRelease.entitlements")
        let capability = try XCTUnwrap(DeveloperIDReleaseCapability.fromEntitlementsPlist(at: url))
        XCTAssertEqual(capability, .expectedDeveloperIDRelease)
    }

    func test_fullMacEntitlements_exposeProfiledCapabilities() throws {
        let url = repoRoot.appendingPathComponent("AgentLens/Resources/OpenBurnBar.entitlements")
        let capability = try XCTUnwrap(DeveloperIDReleaseCapability.fromEntitlementsPlist(at: url))
        XCTAssertEqual(capability, .expectedFullMacApp)
    }

    func test_releaseLaneDoesNotSilentlyClaimKeychainGroups() throws {
        let release = try XCTUnwrap(
            DeveloperIDReleaseCapability.fromEntitlementsPlist(
                at: repoRoot.appendingPathComponent("AgentLens/Resources/OpenBurnBarRelease.entitlements")
            )
        )
        XCTAssertFalse(release.keychainAccessGroups)
        XCTAssertFalse(release.iCloudDocuments)
        XCTAssertFalse(release.appleSignIn)
    }
}
