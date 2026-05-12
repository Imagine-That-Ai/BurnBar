import Foundation
import OpenBurnBarCore

// MARK: - Smart Display Repair Coordinator
//
// Single macOS owner for "make the displays work". iOS/iPad publish
// actions, but the Mac is the only process that can cast to Google devices,
// host DashCast HTML, configure stock Ulanzi simulator mode, and push AWTRIX.

@MainActor
final class SmartDisplayRepairCoordinator {
    private let smartHubBridgeController: SmartHubBridgeController
    private let pixelClockController: PixelClockController

    init(
        smartHubBridgeController: SmartHubBridgeController,
        pixelClockController: PixelClockController
    ) {
        self.smartHubBridgeController = smartHubBridgeController
        self.pixelClockController = pixelClockController
    }

    func repairNestHub(
        progress: ((SmartDisplayDeviceRepairStatus) -> Void)? = nil
    ) async -> SmartDisplayDeviceRepairStatus {
        await smartHubBridgeController.repairNestHubDisplay(progress: progress)
    }

    func repairPixelClock(
        progress: ((SmartDisplayDeviceRepairStatus) -> Void)? = nil
    ) async -> SmartDisplayDeviceRepairStatus {
        await pixelClockController.repairPixelClockDisplay(progress: progress)
    }

    func repairAll(
        progress: ((SmartDisplayRepairReport) -> Void)? = nil
    ) async -> SmartDisplayRepairReport {
        let startedAt = Date()
        progress?(SmartDisplayRepairReport(startedAt: startedAt))

        let nestHub = await repairNestHub { status in
            progress?(SmartDisplayRepairReport(nestHub: status, startedAt: startedAt))
        }
        progress?(SmartDisplayRepairReport(nestHub: nestHub, startedAt: startedAt))

        let pixelClock = await repairPixelClock { status in
            progress?(SmartDisplayRepairReport(nestHub: nestHub, pixelClock: status, startedAt: startedAt))
        }
        var report = SmartDisplayRepairReport(nestHub: nestHub, pixelClock: pixelClock, startedAt: startedAt)
        report.completedAt = Date()
        progress?(report)
        return report
    }
}
