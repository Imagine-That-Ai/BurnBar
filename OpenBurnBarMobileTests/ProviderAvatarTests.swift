import XCTest
import SwiftUI
@testable import OpenBurnBarMobile
import OpenBurnBarCore

final class ProviderAvatarTests: XCTestCase {

    /// Every `AgentProvider.allCases` must resolve a bundled image asset on iOS.
    func testEveryProviderHasBundledLogo() {
        for provider in AgentProvider.allCases {
            let name = provider.bundledLogoName
            let image = UIImage(named: name)
            XCTAssertNotNil(image, "Provider \(provider.displayName) missing bundled asset: \(name)")
        }
    }

    func testProviderAvatarModesRender() {
        for provider in AgentProvider.allCases {
            let plain = ProviderAvatar(provider: provider, mode: .plain, size: 24)
            let tile = ProviderAvatar(provider: provider, mode: .tile, size: 40)
            let aurora = ProviderAvatar(provider: provider, mode: .aurora, size: 48)

            // Verify body does not crash
            _ = plain.body
            _ = tile.body
            _ = aurora.body
        }
    }

    func testBundledLogoNameConsistency() {
        for provider in AgentProvider.allCases {
            let name = provider.bundledLogoName
            XCTAssertTrue(name.hasSuffix("Logo"), "Logo name should end with 'Logo': \(name)")
        }
    }

    func testPiAgentDoesNotReuseHermesLogo() {
        XCTAssertEqual(AgentProvider.piAgent.bundledLogoName, "PiAgentLogo")
        XCTAssertNotEqual(AgentProvider.piAgent.bundledLogoName, AgentProvider.hermes.bundledLogoName)
    }
}
