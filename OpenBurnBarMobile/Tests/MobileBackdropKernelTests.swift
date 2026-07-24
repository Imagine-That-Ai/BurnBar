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
                "prismatica",
                "moire",
                "volumetric",
                "iridescence",
                "gyroid",
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
                "agent1",
                "neural-bloom",
                "aether-lattice",
                "bat-signal",
                "storm-signal",
                "origami",
                "ink-diffusion",
                "petroleum-sheen",
                "boids",
                "voxel",
                "star-atlas",
                "sky-ascent",
                "open-world-armada",
                "genesis",
                "singularity",
                "knot-field",
                "hypersphere"
            ]
        )
        XCTAssertEqual(MobileBackdropKernel.allCases.count, 42)
    }

    func testDefaultKeepsFirstLaunchOnOriginalDotBackdrop() {
        XCTAssertEqual(MobileBackdropKernel.defaultKernel, .constellation)
        XCTAssertEqual(MobileBackdropKernel.defaultKernel.rawValue, "constellation")
    }

    func testAppBackdropOnlyOffersBundledWebGLKernels() {
        XCTAssertEqual(MobileBackdropKernel.appBackdropKernels.count, 31)
        XCTAssertTrue(MobileBackdropKernel.appBackdropKernels.contains(.fluidAurora))
        XCTAssertFalse(MobileBackdropKernel.appBackdropKernels.contains(.prismatica))
        XCTAssertFalse(MobileBackdropKernel.appBackdropKernels.contains(.hypersphere))
    }

    func testLivingThemeSelectionDoesNotMutateAppBackdropPreference() {
        XCTAssertNotEqual(MobileBackdropKernel.livingThemeStorageKey, MobileBackdropKernel.storageKey)
    }

    func testInvalidStoredKernelFallsBackToDefault() {
        XCTAssertEqual(MobileBackdropKernel.resolved("petroleum-sheen"), .petroleumSheen)
        XCTAssertEqual(MobileBackdropKernel.resolved("not-a-kernel"), .constellation)
    }

    func testLabelsAndBlurbsAreAvailableForPicker() {
        for kernel in MobileBackdropKernel.allCases {
            XCTAssertFalse(kernel.label.isEmpty)
            XCTAssertFalse(kernel.blurb.isEmpty)
        }
    }

    func testNativeKernelFrameRateSanitizesPowerPlanRates() {
        XCTAssertEqual(MobileKernelBackdropView.sanitizedFrameRate(15), 15)
        XCTAssertEqual(MobileKernelBackdropView.sanitizedFrameRate(30), 30)
        XCTAssertEqual(MobileKernelBackdropView.sanitizedFrameRate(120), 30)
        XCTAssertEqual(MobileKernelBackdropView.sanitizedFrameRate(nil), 30)
        XCTAssertEqual(MobileKernelBackdropView.sanitizedFrameRate(.nan), 30)
        XCTAssertEqual(MobileKernelBackdropView.sanitizedFrameRate(0), 30)
    }
}
