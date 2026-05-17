#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import SwiftUI

/// Production app owner for the Mac-side Computer Use coordinator.
///
/// `ComputerUseSessionCoordinator` is intentionally session-scoped. This
/// object is process-scoped: it installs the iroh `control.*` dispatcher on
/// the live relay client, owns the panic-hotkey monitor, and exposes the panel
/// model Settings renders. Without this owner the coordinator can compile but
/// never receives phone-control frames in the running app.
@MainActor
final class ComputerUseRuntimeController: ObservableObject, @unchecked Sendable {
    static let computerUseProductId = "com.openburnbar.hostedComputerUseSync.monthly"

    @Published private(set) var coordinator: ComputerUseSessionCoordinator
    let panelModel = ComputerUseSessionPanelModel()

    private let accountManager: AccountManager
    private let settingsManager: SettingsManager
    private weak var cloudSyncService: CloudSyncService?
    private var panicCoordinator: ComputerUsePanicHaltCoordinator?
    private var cancellables: Set<AnyCancellable> = []

    init(
        accountManager: AccountManager,
        settingsManager: SettingsManager,
        cloudSyncService: CloudSyncService? = nil
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.cloudSyncService = cloudSyncService
        self.coordinator = Self.makeCoordinator(
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        configurePanelModel()
        bindCoordinator()
        refreshEntitlement()
    }

    func attach(cloudSyncService: CloudSyncService) {
        self.cloudSyncService = cloudSyncService
        cloudSyncService.setComputerUseControlDispatcher(coordinator.controlDispatcher)
    }

    func startPanicMonitoring() {
        guard panicCoordinator == nil else { return }
        let panic = ComputerUsePanicHaltCoordinator { [weak self] source in
            Task { @MainActor in
                await self?.coordinator.panicHalt(source: source)
            }
        }
        panic.install()
        panicCoordinator = panic
    }

    func refreshEntitlement() {
        MacCloudEntitlementStore.shared.start()
        let entitlement = ComputerUseEntitlementSnapshot(
            isActive: MacCloudEntitlementStore.shared.hostedComputerUseIsActive,
            productId: Self.computerUseProductId,
            expireAt: MacCloudEntitlementStore.shared.hostedComputerUseExpirationDate,
            allowsBrowser: true,
            allowsSystem: true,
            allowsPhoneControl: true,
            allowsTrustedScopes: true,
            allowsAuditExport: true
        )
        coordinator.updateEntitlement(entitlement)
    }

    @discardableResult
    func startSystemSession(trustMode: ComputerUseTrustMode = .manual) async throws -> ComputerUseSessionStartResponse {
        refreshEntitlement()
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.system.rawValue,
            trustMode: trustMode.rawValue,
            scopeRuleIds: panelModel.scopeRules.map { $0.id.rawValue },
            macHostNodeId: accountManager.deviceId,
            actionCap: ComputerUseBudgetEnvelope.initialNormal.activeActionsPerRun,
            sessionTimeoutSeconds: 1800,
            clientID: BurnBarClientID(rawValue: accountManager.userID ?? "local-\(accountManager.deviceId)")
        )
        return try await coordinator.startSession(request: request)
    }

    func endSession() async {
        await coordinator.endSession(reason: .userHalt)
    }

    private func configurePanelModel() {
        panelModel.scopeRules = ComputerUseDenyRegistry.builtInRules
        panelModel.setTrustMode = { [weak self] mode in
            self?.coordinator.setTrustMode(mode)
        }
        panelModel.addRule = { [weak self] rule in
            guard let self else { return }
            self.panelModel.scopeRules.append(rule)
        }
        panelModel.removeRule = { [weak self] id in
            self?.panelModel.scopeRules.removeAll { $0.id == id && $0.origin == .user }
        }
        panelModel.panicHalt = { [weak self] in
            Task { @MainActor in
                await self?.coordinator.panicHalt(source: .stalled)
            }
        }
    }

    private func bindCoordinator() {
        coordinator.$state
            .sink { [weak self] state in
                guard let self else { return }
                self.panelModel.liveTrustMode = state?.liveTrustMode ?? .manual
                self.panelModel.auditHeadHashHex = state?.auditChainHeadHashHex
                self.panelModel.currentSessionStartedAt = state?.manifest.startedAt
            }
            .store(in: &cancellables)

        coordinator.$actionTimeline
            .sink { [weak self] timeline in
                self?.panelModel.recentAuditEntries = timeline.reversed()
            }
            .store(in: &cancellables)
    }

    private static func makeCoordinator(
        accountManager: AccountManager,
        settingsManager: SettingsManager
    ) -> ComputerUseSessionCoordinator {
        let supportDirectory = OpenBurnBarAppPaths.live().supportDirectory
        let auditDirectory = supportDirectory.appendingPathComponent("computer-use-audit", isDirectory: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: accountManager.userID ?? "local-\(accountManager.deviceId)",
                macHostNodeId: accountManager.deviceId,
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: false,
                    productId: computerUseProductId,
                    allowsBrowser: true,
                    allowsSystem: true,
                    allowsPhoneControl: true,
                    allowsTrustedScopes: true,
                    allowsAuditExport: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: Self.todayKey()),
                auditBaseDirectory: auditDirectory,
                macAppVersion: version,
                killSwitch: settingsManager.computerUseKillSwitch
            ),
            scopeRulesProvider: { ComputerUseDenyRegistry.builtInRules },
            approvalPresenter: { request, screenshot in
                await ComputerUseRuntimeController.presentApproval(request, screenshot: screenshot)
            }
        )
    }

    private static func presentApproval(
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
                styleMask: [.titled, .closable, .nonactivatingPanel],
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

    private static func todayKey(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
#endif
