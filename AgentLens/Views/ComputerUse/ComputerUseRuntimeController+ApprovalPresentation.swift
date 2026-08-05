#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import SwiftUI

extension ComputerUseRuntimeController {
    static func presentApproval(
        _ request: HermesRealtimeRelayApprovalRequest,
        screenshot: Data?
    ) async -> HermesRealtimeRelayApprovalResponse {
        await ComputerUseApprovalPanelSession.present(request, screenshot: screenshot)
    }
}

enum ComputerUseApprovalPanelResolutionSource: Equatable {
    case decision
    case windowClose

    var shouldClosePanel: Bool {
        self == .decision
    }
}

@MainActor
private final class ComputerUseApprovalPanelSession: NSObject, NSWindowDelegate {
    private static var liveSessions: [String: ComputerUseApprovalPanelSession] = [:]

    private let request: HermesRealtimeRelayApprovalRequest
    private let screenshot: Data?
    private var continuation: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Never>?
    private var panel: NSPanel?
    private var didResolve = false

    private init(
        request: HermesRealtimeRelayApprovalRequest,
        screenshot: Data?,
        continuation: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Never>
    ) {
        self.request = request
        self.screenshot = screenshot
        self.continuation = continuation
        super.init()
    }

    static func present(
        _ request: HermesRealtimeRelayApprovalRequest,
        screenshot: Data?
    ) async -> HermesRealtimeRelayApprovalResponse {
        await withCheckedContinuation { continuation in
            let session = ComputerUseApprovalPanelSession(
                request: request,
                screenshot: screenshot,
                continuation: continuation
            )
            liveSessions[request.approvalId] = session
            session.show()
        }
    }

    private func show() {
        let root = ComputerUseApprovalSheet(
            request: request,
            beforeScreenshotPNG: screenshot,
            liveTrustMode: request.trustMode.flatMap(ComputerUseTrustMode.init(rawValue:)) ?? .manual,
            onDecision: { [weak self] outcome in
                self?.resolve(outcome: outcome, note: outcome.approveBurst ? "Step-mode burst approved from Mac" : nil)
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
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: root)
        panel.center()
        self.panel = panel
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.resolve(
                decision: .reject,
                note: "Approval panel was closed before a decision was made.",
                source: .windowClose
            )
        }
    }

    private func resolve(
        outcome: ComputerUseApprovalSheet.Outcome,
        note: String?
    ) {
        let decision: HermesRealtimeRelayApprovalResponse.Decision
        switch outcome.decision {
        case .approve: decision = .approve
        case .reject: decision = .reject
        case .rejectAndHalt: decision = .rejectAndHalt
        }
        resolve(decision: decision, note: note, source: .decision)
    }

    private func resolve(
        decision: HermesRealtimeRelayApprovalResponse.Decision,
        note: String?,
        source: ComputerUseApprovalPanelResolutionSource
    ) {
        guard !didResolve else { return }
        didResolve = true

        let response = HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: decision,
            respondedBy: "mac",
            respondedAt: Date(),
            note: note
        )
        continuation?.resume(returning: response)
        continuation = nil

        let activePanel = panel
        panel = nil
        activePanel?.delegate = nil
        if source.shouldClosePanel {
            activePanel?.close()
        }

        Self.liveSessions[request.approvalId] = nil
    }
}
#endif
