#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import SwiftUI

/// App-wide presenter for daemon-originated Computer Use approvals.
///
/// Browser-mode Computer Use runs in `OpenBurnBarDaemon`, but approval is a
/// user-facing Mac responsibility. This presenter polls the daemon's pending
/// approval bridge and shows one floating panel regardless of whether Settings,
/// Dashboard, or the menu-bar popover is currently open.
@MainActor
final class ComputerUseDaemonApprovalPresenter {
    static let shared = ComputerUseDaemonApprovalPresenter()

    private var daemonManager: OpenBurnBarDaemonManager?
    private var pollTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var activeApprovalId: String?
    private var lastError: String?

    private init() {}

    private static let cadenceID = "computer-use-daemon-approval-poll"

    func start(daemonManager: OpenBurnBarDaemonManager) {
        self.daemonManager = daemonManager
        guard pollTask == nil else { return }
        // Coordinator-managed cadence: 750 ms active, 5 s background,
        // paused on display sleep. Approvals are user-facing — the
        // moment a request shows up we want the panel up — but the
        // poll has zero cost when the laptop sleeps. The cadence
        // gates itself behind daemon health so we never spam the
        // bridge while the daemon is restarting.
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceID,
                activeInterval: 0.75,
                backgroundInterval: 5,
                sleepInterval: nil,
                isEnabled: { [weak self] in
                    guard let daemonManager = self?.daemonManager else { return false }
                    if case .healthy = daemonManager.status { return true }
                    return false
                },
                fireImmediately: false,
                cancellableInFlight: false,
                work: { [weak self] in
                    await self?.pollOnce()
                }
            )
        )
        pollTask = Task { @MainActor in }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        BackgroundCadenceCoordinator.shared.unregister(id: Self.cadenceID)
        closePanel()
    }

    private func pollOnce() async {
        guard let daemonManager else { return }
        guard activeApprovalId == nil else { return }
        do {
            let response = try await daemonManager.pendingComputerUseApprovals()
            if let request = response.requests.first {
                present(request, daemonManager: daemonManager)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func present(
        _ request: HermesRealtimeRelayApprovalRequest,
        daemonManager: OpenBurnBarDaemonManager
    ) {
        guard activeApprovalId == nil else { return }
        activeApprovalId = request.approvalId

        let trustMode = request.trustMode.flatMap(ComputerUseTrustMode.init(rawValue:)) ?? .manual
        let root = ComputerUseApprovalSheet(
            request: request,
            liveTrustMode: trustMode
        ) { [weak self] outcome in
            Task { @MainActor in
                await self?.respond(
                    request,
                    outcome: outcome,
                    daemonManager: daemonManager
                )
            }
        }

        let hostingView = NSHostingView(rootView: root)
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
        panel.contentView = hostingView
        panel.center()

        self.panel = panel
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func respond(
        _ request: HermesRealtimeRelayApprovalRequest,
        outcome: ComputerUseApprovalSheet.Outcome,
        daemonManager: OpenBurnBarDaemonManager
    ) async {
        let decision: HermesRealtimeRelayApprovalResponse.Decision
        switch outcome.decision {
        case .approve:
            decision = .approve
        case .reject:
            decision = .reject
        case .rejectAndHalt:
            decision = .rejectAndHalt
        }

        closePanel()
        do {
            _ = try await daemonManager.respondToComputerUseApproval(
                ComputerUseApprovalRespondRequest(
                    sessionId: request.sessionId,
                    response: HermesRealtimeRelayApprovalResponse(
                        approvalId: request.approvalId,
                        decision: decision,
                        respondedBy: "mac",
                        respondedAt: Date(),
                        note: outcome.approveBurst ? "Step-mode burst approved from Mac" : nil
                    )
                )
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        activeApprovalId = nil
    }
}
#endif
