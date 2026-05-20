#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import Foundation
@preconcurrency import FirebaseFirestore
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
    private weak var relayHostService: HermesRelayHostService?
    private var panicCoordinator: ComputerUsePanicHaltCoordinator?
    private var cancellables: Set<AnyCancellable> = []
    #if DEBUG
    private var didStartE2EProofSession = false
    #endif

    init(
        accountManager: AccountManager,
        settingsManager: SettingsManager,
        relayHostService: HermesRelayHostService? = nil
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.relayHostService = relayHostService
        self.coordinator = Self.makeCoordinator(
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        configurePanelModel()
        bindCoordinator()
        refreshEntitlement()
    }

    func attach(relayHostService: HermesRelayHostService) {
        self.relayHostService = relayHostService
        relayHostService.setComputerUseControlDispatcher(coordinator.controlDispatcher)
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

    func stopPanicMonitoring() {
        panicCoordinator?.uninstall()
        panicCoordinator = nil
    }

    #if DEBUG
    func startE2EProofSessionIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF"] == "1" else { return }
        guard !didStartE2EProofSession else { return }
        didStartE2EProofSession = true
        Task { @MainActor in
            do {
                try await waitForComputerUseEntitlementForE2E()
                try await waitForAccessibilityForE2E()
                let response = try await startSystemSession(trustMode: .manual)
                Self.recordE2EProofEvent([
                    "event": "mac_session_started",
                    "sessionId": response.sessionId,
                    "auditHead": response.manifestHashHex
                ])
            } catch {
                Self.recordE2EProofEvent([
                    "event": "mac_session_failed",
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func waitForComputerUseEntitlementForE2E() async throws {
        let store = MacCloudEntitlementStore.shared
        store.start()
        for _ in 0..<50 {
            refreshEntitlement()
            if store.hostedComputerUseIsActive {
                Self.recordE2EProofEvent(["event": "mac_entitlement_active"])
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        Self.recordE2EProofEvent(["event": "mac_entitlement_wait_timed_out"])
    }

    private func waitForAccessibilityForE2E() async throws {
        if AXIsProcessTrusted() {
            Self.recordE2EProofEvent(["event": "mac_accessibility_trusted"])
            return
        }
        Self.recordE2EProofEvent(["event": "mac_accessibility_prompted"])
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        for _ in 0..<150 {
            if AXIsProcessTrusted() {
                Self.recordE2EProofEvent(["event": "mac_accessibility_trusted"])
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        Self.recordE2EProofEvent(["event": "mac_accessibility_wait_timed_out"])
    }

    private static func recordE2EProofEvent(_ fields: [String: String]) {
        var record = fields
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        record["timestampMillis"] = String(Int(Date().timeIntervalSince1970 * 1000))
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        print("OpenBurnBar ComputerUseE2E \(line)")
        guard let path = ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF_OUTPUT"],
              !path.isEmpty,
              let lineData = "\(line)\n".data(using: .utf8)
        else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
            try? handle.close()
        }
    }
    #endif

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

    func publishAuditExportSignerReadback(for response: ComputerUseAuditExportResponse) async throws {
        guard let uid = accountManager.userID, !uid.isEmpty else {
            throw ComputerUseAuditExportSignerPublisherError.missingUserId
        }
        try await ComputerUseAuditExportSignerPublisher.shared.publish(
            uid: uid,
            deviceId: accountManager.deviceId,
            response: response
        )
    }

    @discardableResult
    func startSystemSession(trustMode: ComputerUseTrustMode = .manual) async throws -> ComputerUseSessionStartResponse {
        refreshEntitlement()
        #if DEBUG
        let proofActionCap = ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_ACTION_CAP"]
            .flatMap(Int.init)
            .map { max(1, min($0, 500)) }
        #else
        let proofActionCap: Int? = nil
        #endif
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.system.rawValue,
            trustMode: trustMode.rawValue,
            scopeRuleIds: panelModel.scopeRules.map { $0.id.rawValue },
            macHostNodeId: accountManager.deviceId,
            actionCap: proofActionCap ?? ComputerUseBudgetEnvelope.initialNormal.activeActionsPerRun,
            sessionTimeoutSeconds: 1800,
            clientID: BurnBarClientID(rawValue: accountManager.userID ?? "local-\(accountManager.deviceId)")
        )
        let response = try await coordinator.startSession(request: request)
        startPanicMonitoring()
        return response
    }

    func endSession() async {
        await coordinator.endSession(reason: .userHalt)
        stopPanicMonitoring()
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
        MacCloudEntitlementStore.shared.$hostedComputerUseIsActive
            .combineLatest(MacCloudEntitlementStore.shared.$hostedComputerUseExpirationDate)
            .sink { [weak self] _, _ in
                self?.refreshEntitlement()
            }
            .store(in: &cancellables)

        coordinator.$state
            .sink { [weak self] state in
                guard let self else { return }
                self.panelModel.liveTrustMode = state?.liveTrustMode ?? .manual
                self.panelModel.auditHeadHashHex = state?.auditChainHeadHashHex
                self.panelModel.currentSessionStartedAt = state?.manifest.startedAt
                if state == nil {
                    self.stopPanicMonitoring()
                }
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

    private static func todayKey(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}

private enum ComputerUseAuditExportSignerPublisherError: LocalizedError {
    case missingUserId
    case unsignedArchive

    var errorDescription: String? {
        switch self {
        case .missingUserId:
            return "Cannot publish audit-export signer readback before the Mac is signed in."
        case .unsignedArchive:
            return "Cannot publish audit-export signer readback because the daemon did not return signature public-key metadata."
        }
    }
}

private final class ComputerUseAuditExportSignerPublisher: @unchecked Sendable {
    static let shared = ComputerUseAuditExportSignerPublisher()

    private let firestoreProvider: @Sendable () -> Firestore

    init(firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func publish(
        uid: String,
        deviceId: String,
        response: ComputerUseAuditExportResponse
    ) async throws {
        guard let algorithm = response.signatureAlgorithm,
              let signerIdentifier = response.signatureSignerIdentifier,
              let signerKind = response.signatureSignerKind,
              let trustRoot = response.signatureTrustRoot,
              let publicKeyBase64 = response.signaturePublicKeyBase64,
              let publicKeySHA256Hex = response.signaturePublicKeySHA256Hex else {
            throw ComputerUseAuditExportSignerPublisherError.unsignedArchive
        }
        let nowMillis = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let payload: [String: Any] = [
            "id": publicKeySHA256Hex,
            "userId": uid,
            "deviceId": deviceId,
            "signerIdentifier": signerIdentifier,
            "signerKind": signerKind,
            "trustRoot": trustRoot,
            "algorithm": algorithm,
            "publicKeyBase64": publicKeyBase64,
            "publicKeySHA256Hex": publicKeySHA256Hex,
            "status": "active",
            "publishedAtMillis": nowMillis,
            "lastReadbackAtMillis": nowMillis,
            "schemaVersion": 1
        ]
        try await firestoreProvider()
            .collection("users").document(uid)
            .collection("escrow_devices").document(deviceId)
            .collection("computer_use_audit_export_signers").document(publicKeySHA256Hex)
            .setData(payload, merge: true)
    }
}
#endif
