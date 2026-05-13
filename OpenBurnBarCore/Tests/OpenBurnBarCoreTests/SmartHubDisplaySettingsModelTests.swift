import XCTest
@testable import OpenBurnBarCore

@MainActor
final class SmartHubDisplaySettingsModelTests: XCTestCase {
    func testRepairMarksBridgeBoundWhenDisplayProofIsHealthy() async throws {
        let operations = InMemorySmartHubDisplayOperations(probeResult: .bound)
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: operations
        )

        await model.repair()

        XCTAssertEqual(model.lastRepairStatus?.phase, .working)
        XCTAssertEqual(model.bridgeStatus, .bound)
        XCTAssertEqual(model.bridgeStatusMessage, "Nest Hub is showing OpenBurnBar.")
        XCTAssertEqual(model.operationState.lastSucceededKind, .repair)
        XCTAssertEqual(operations.refreshCount, 1)
    }

    func testRepairFailureSurfacesRepairMessageAndUnreachableStatus() async throws {
        let operations = InMemorySmartHubDisplayOperations(probeResult: .unreachable)
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: operations
        )

        await model.repair()

        XCTAssertEqual(model.lastRepairStatus?.phase, .failed)
        XCTAssertEqual(model.bridgeStatus, .unreachable)
        XCTAssertEqual(model.bridgeStatusMessage, "Nest Hub repair failed.")
        // A repair that ends in `.failed` / `.needsUserAction` must NOT
        // surface as a green "completed" banner — the user just saw the
        // orange "no device found" message, so the operation state has
        // to report the same outcome.
        XCTAssertNil(model.operationState.lastSucceededKind)
        XCTAssertEqual(model.operationState.failureMessage, "Nest Hub repair failed.")
    }

    func testRepairNeedsUserActionSurfacesAsFailureNotSuccess() async throws {
        let operations = InMemorySmartHubDisplayOperations(
            probeResult: .unreachable,
            repairOverride: SmartDisplayDeviceRepairStatus(
                kind: .nestHub,
                phase: .needsUserAction,
                message: "No display-capable Google Cast device was found.",
                proof: "cast_device_not_found"
            )
        )
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: operations
        )

        await model.repair()

        XCTAssertEqual(model.lastRepairStatus?.phase, .needsUserAction)
        XCTAssertEqual(model.bridgeStatus, .unreachable)
        XCTAssertNil(model.operationState.lastSucceededKind)
        XCTAssertEqual(
            model.operationState.failureMessage,
            "No display-capable Google Cast device was found."
        )
    }

    func testRepairOperationCopyUsesOneClickLanguage() throws {
        XCTAssertEqual(SmartHubDisplayOperationKind.repair.displayName, "Make display work")
        XCTAssertEqual(SmartHubDisplayOperationKind.repair.inFlightLabel, "Repairing…")
        XCTAssertEqual(SmartHubDisplayOperationKind.repair.symbolName, "wand.and.stars")
    }

    func testEnableToggleRunsRepairPath() async throws {
        let operations = InMemorySmartHubDisplayOperations(probeResult: .bound)
        var persistedEnabled: Bool?
        let model = SmartHubDisplaySettingsModel(
            enabled: false,
            initialConfig: .default,
            operations: operations,
            onEnabledChange: { persistedEnabled = $0 }
        )

        await model.setEnabledFromToggle(true)

        XCTAssertTrue(model.enabled)
        XCTAssertEqual(persistedEnabled, true)
        XCTAssertEqual(model.lastRepairStatus?.phase, .working)
        XCTAssertEqual(model.operationState.lastSucceededKind, .repair)
        XCTAssertEqual(operations.refreshCount, 1)
    }

    func testDisableToggleStopsBridgeAndPersistsOff() async throws {
        let operations = InMemorySmartHubDisplayOperations(probeResult: .bound)
        var persistedEnabled: Bool?
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: operations,
            onEnabledChange: { persistedEnabled = $0 }
        )

        await model.setEnabledFromToggle(false)

        XCTAssertFalse(model.enabled)
        XCTAssertEqual(persistedEnabled, false)
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(model.operationState.lastSucceededKind, .stop)
    }
}
