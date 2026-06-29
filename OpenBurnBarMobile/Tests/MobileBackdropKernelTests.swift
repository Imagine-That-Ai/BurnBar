import XCTest
@testable import OpenBurnBarMobile

final class MobileBackdropKernelTests: XCTestCase {
    func testKernelIDsMatchAppBurnbarRegistryOrder() {
        XCTAssertEqual(
            MobileBackdropKernel.websiteKernelIDs,
            [
                "constellation",
                "flow",
                "aurora",
                "mesh",
                "moire",
                "volumetric",
                "lic",
                "fluid-aurora",
                "cloudfield",
                "plasma-orbs",
                "blobs-mesh",
                "retro-plasma",
                "inversion-lattice",
                "vogel-bloom",
                "crystal-drift",
                "ripple-lattice",
                "liquid-lumen",
                "spectral-drift",
                "mycelium-mesh",
                "oilfield",
                "suminagashi-drift",
                "kinetic-stipple",
                "neural-bloom",
                "agent1",
                "aether-lattice",
                "bat-signal",
                "storm-signal",
                "origami",
                "ink-diffusion",
                "petroleum-sheen"
            ]
        )
    }

    func testDefaultMatchesWebsitePersistedBackdropDefault() {
        XCTAssertEqual(MobileBackdropKernel.defaultKernel, .fluidAurora)
        XCTAssertEqual(MobileBackdropKernel.defaultKernel.rawValue, "fluid-aurora")
    }

    func testInvalidStoredKernelFallsBackToDefault() {
        XCTAssertEqual(MobileBackdropKernel.resolved("petroleum-sheen"), .petroleumSheen)
        XCTAssertEqual(MobileBackdropKernel.resolved("not-a-kernel"), .fluidAurora)
    }

    func testLabelsAndBlurbsAreAvailableForPicker() {
        for kernel in MobileBackdropKernel.allCases {
            XCTAssertFalse(kernel.label.isEmpty)
            XCTAssertFalse(kernel.blurb.isEmpty)
        }
    }
}
