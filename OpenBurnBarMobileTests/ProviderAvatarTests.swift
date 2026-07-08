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

    @MainActor
    func testProviderAvatarModesRender() {
        for provider in AgentProvider.allCases {
            let plain = ProviderAvatar(provider: provider, mode: .plain, size: 24)
            let tile = ProviderAvatar(provider: provider, mode: .tile, size: 40)
            let aurora = ProviderAvatar(provider: provider, mode: .aurora, size: 48)

            XCTAssertHostsNonZero(plain, size: 24)
            XCTAssertHostsNonZero(tile, size: 40)
            XCTAssertHostsNonZero(aurora, size: 48)
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

    @MainActor
    private func XCTAssertHostsNonZero<V: View>(
        _ view: V,
        size: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.width, 0, file: file, line: line)
        XCTAssertGreaterThan(host.view.bounds.height, 0, file: file, line: line)
    }
}
