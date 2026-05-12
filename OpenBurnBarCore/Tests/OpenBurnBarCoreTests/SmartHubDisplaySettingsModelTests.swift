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
        XCTAssertEqual(model.operationState.lastSucceededKind, .repair)
    }

    func testRepairOperationCopyUsesOneClickLanguage() throws {
        XCTAssertEqual(SmartHubDisplayOperationKind.repair.displayName, "Make display work")
        XCTAssertEqual(SmartHubDisplayOperationKind.repair.inFlightLabel, "Repairing…")
        XCTAssertEqual(SmartHubDisplayOperationKind.repair.symbolName, "wand.and.stars")
    }
}
