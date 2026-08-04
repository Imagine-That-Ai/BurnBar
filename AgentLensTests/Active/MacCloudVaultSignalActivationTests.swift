import XCTest
@testable import OpenBurnBar

final class MacCloudVaultSignalActivationTests: XCTestCase {
    func test_activationPolicy_isOffWithoutSchemeOrEnablement() {
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: false,
                enabled: true,
                required: true,
                hardKill: false
            ),
            .off
        )
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: true,
                enabled: false,
                required: true,
                hardKill: false
            ),
            .off
        )
    }

    func test_activationPolicy_distinguishesEnabledFromRequired() {
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: true,
                enabled: true,
                required: false,
                hardKill: false
            ),
            .enabled
        )
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: true,
                enabled: true,
                required: true,
                hardKill: false
            ),
            .required
        )
    }

    func test_activationPolicy_hardKillOverridesRequiredMode() {
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: true,
                enabled: true,
                required: true,
                hardKill: true
            ),
            .off
        )
    }
}
