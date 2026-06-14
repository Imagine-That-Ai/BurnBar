#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Foundation
import OpenBurnBarCore
import SwiftUI

extension ComputerUseRuntimeController {
    static func presentApproval(
        _ request: HermesRealtimeRelayApprovalRequest,
        screenshot: Data?
    ) async -> HermesRealtimeRelayApprovalResponse {
        await withCheckedContinuation { continuation in
            let root = ComputerUseApprovalSheet(
                request: request,
                beforeScreenshotPNG: screenshot,
                liveTrustMode: request.trustMode.flatMap(ComputerUseTrustMode.init(rawValue:)) ?? .manual,
                onDecision: { outcome in
                    let decision: HermesRealtimeRelayApprovalResponse.Decision
                    switch outcome.decision {
                    case .approve: decision = .approve
                    case .reject: decision = .reject
                    case .rejectAndHalt: decision = .rejectAndHalt
                    }
                    continuation.resume(returning: HermesRealtimeRelayApprovalResponse(
                        approvalId: request.approvalId,
                        decision: decision,
                        respondedBy: "mac",
                        respondedAt: Date(),
                        note: outcome.approveBurst ? "Step-mode burst approved from Mac" : nil
                    ))
                }
            )
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Computer Use Approval"
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = true
            panel.contentView = NSHostingView(rootView: root)
            panel.center()
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
#endif
