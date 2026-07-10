import FirebaseAuth
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

extension OpenBurnBarDaemonManager {
    func startComputerUseSession(
        _ request: ComputerUseSessionStartRequest,
        concurrentSessionActive: Bool = false
    ) async throws -> ComputerUseSessionStartResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before starting Computer Use.")
        }
        _ = try await publishComputerUseCapabilityState(
            concurrentSessionActive: concurrentSessionActive
        )
        let socketURL = paths.socketURL
        let response = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.startComputerUseSession(request, at: socketURL)
        }
        enqueueComputerUseSessionStartMetering(request: request, response: response)
        return response
    }

    func invokeComputerUse(
        _ request: ComputerUseInvokeRequest,
        concurrentSessionActive: Bool = false
    ) async throws -> ComputerUseInvokeResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before invoking Computer Use.")
        }
        _ = try await publishComputerUseCapabilityState(
            concurrentSessionActive: concurrentSessionActive
        )
        let socketURL = paths.socketURL
        let response = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.invokeComputerUse(request, at: socketURL)
        }
        enqueueComputerUseActionMetering(request: request, response: response)
        return response
    }

    @discardableResult
    func publishComputerUseCapabilityState(
        concurrentSessionActive: Bool = false,
        authorizationRevoked: Bool = false
    ) async throws -> ComputerUseCapabilityStateUpdateResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError(
                "OpenBurnBar daemon must be healthy before publishing Computer Use capability state."
            )
        }

        let entitlementStore = MacCloudEntitlementStore.shared
        let budgetStore = computerUseBudgetStatusStore
        let quotaStore = computerUseQuotaUsageStore
        entitlementStore.start()
        budgetStore.startListening()
        quotaStore.startListening()
        await entitlementStore.refreshComputerUseAuthorityIfNeeded()
        await budgetStore.refreshFromServerIfNeeded()
        await quotaStore.refreshFromServerIfNeeded()

        let now = Date()
        let userID = Auth.auth().currentUser?.uid ?? ""
        let entitlement = ComputerUseEntitlementSnapshot(
            isActive: entitlementStore.hostedComputerUseIsActive,
            productId: ComputerUseRuntimeController.computerUseProductId,
            expireAt: entitlementStore.hostedComputerUseExpirationDate,
            allowsBrowser: settingsManager.computerUseBrowserEnabled,
            allowsSystem: settingsManager.computerUseSystemEnabled,
            allowsPhoneControl: settingsManager.computerUsePhoneControlEnabled,
            allowsTrustedScopes: settingsManager.computerUseTrustedScopesEnabled,
            allowsAuditExport: settingsManager.computerUseAuditExportEnabled
        )
        let unavailableProvenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: .distantPast
        )
        let entitlementProvenance = entitlementStore.computerUseAuthorityProvenance
            ?? unavailableProvenance
        let budgetProvenance = budgetStore.authorityProvenance ?? unavailableProvenance
        let quotaProvenance = quotaStore.authorityProvenance ?? unavailableProvenance
        let complete = !userID.isEmpty
            && entitlementStore.hasAuthoritativeComputerUseEntitlementSnapshot
            && budgetStore.hasAuthoritativeSnapshot
            && quotaStore.hasAuthoritativeSnapshot
            && settingsManager.hasResolvedComputerUseRemoteConfig
            && Self.computerUseAuthoritiesAreFresh(
                entitlement: entitlementProvenance,
                budget: budgetProvenance,
                quota: quotaProvenance,
                now: now
            )

        computerUseCapabilityRevision &+= 1
        let state = ComputerUseCapabilityStateSnapshot(
            publisherInstanceID: computerUseCapabilityPublisherInstanceID,
            revision: computerUseCapabilityRevision,
            generatedAt: now,
            userID: userID,
            entitlement: entitlement,
            entitlementProvenance: entitlementProvenance,
            budgetEnvelope: budgetStore.latestEnvelope ?? .hardCapEnvelope(
                projectedMonthEndUSD: 0,
                monthToDateUSD: 0,
                updatedAt: .distantPast
            ),
            budgetProvenance: budgetProvenance,
            quotaUsage: quotaStore.currentUsage ?? ComputerUseQuotaUsage(dayKey: Self.computerUseTodayKey()),
            quotaProvenance: quotaProvenance,
            concurrentSessionActive: concurrentSessionActive,
            killSwitch: settingsManager.computerUseKillSwitch,
            authorizationRevoked: authorizationRevoked,
            isComplete: complete
        )
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.updateComputerUseCapabilityState(
                ComputerUseCapabilityStateUpdateRequest(state: state),
                at: socketURL
            )
        }
    }

    private static func computerUseTodayKey(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private static func computerUseAuthoritiesAreFresh(
        entitlement: ComputerUseAuthorityProvenance,
        budget: ComputerUseAuthorityProvenance,
        quota: ComputerUseAuthorityProvenance,
        now: Date
    ) -> Bool {
        guard ComputerUseCapabilityFreshness.sourceIsFresh(entitlement, now: now),
              ComputerUseCapabilityFreshness.sourceIsFresh(budget, now: now),
              ComputerUseCapabilityFreshness.sourceIsFresh(quota, now: now),
              budget.source == .firestoreServer,
              quota.source == .firestoreServer,
              let budgetUpdatedAt = budget.updatedAt else {
            return false
        }
        return budgetUpdatedAt <= now.addingTimeInterval(ComputerUseCapabilityFreshness.maximumFutureSkew)
            && now.timeIntervalSince(budgetUpdatedAt)
                <= ComputerUseCapabilityFreshness.maximumBudgetUpdateAge
    }

    func provisionPhoneControlPin(
        _ request: DaemonPhoneControlPinProvisionRequest
    ) async throws -> DaemonPhoneControlPinProvisionResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before provisioning phone-control pins.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.provisionPhoneControlPin(request, at: socketURL)
        }
    }

    func pendingComputerUseApprovals(
        _ request: ComputerUseApprovalPendingRequest = ComputerUseApprovalPendingRequest()
    ) async throws -> ComputerUseApprovalPendingResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before reading Computer Use approvals.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.pendingComputerUseApprovals(request, at: socketURL)
        }
    }

    func respondToComputerUseApproval(
        _ request: ComputerUseApprovalRespondRequest
    ) async throws -> ComputerUseApprovalRespondResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before responding to Computer Use approvals.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.respondToComputerUseApproval(request, at: socketURL)
        }
    }

    func panicHaltComputerUse(
        _ request: ComputerUsePanicHaltRequest
    ) async throws -> ComputerUsePanicHaltResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before halting Computer Use.")
        }
        let socketURL = paths.socketURL
        let response = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.panicHaltComputerUse(request, at: socketURL)
        }
        enqueueComputerUseSessionEndMetering(request: request, response: response)
        return response
    }

    func exportComputerUseAudit(
        _ request: ComputerUseAuditExportRequest
    ) async throws -> ComputerUseAuditExportResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before exporting a Computer Use audit archive.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.exportComputerUseAudit(request, at: socketURL)
        }
    }

    private func enqueueComputerUseSessionStartMetering(
        request: ComputerUseSessionStartRequest,
        response: ComputerUseSessionStartResponse
    ) {
        guard let userID = Auth.auth().currentUser?.uid else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        Task { @MainActor in
            do {
                try await computerUseCloudMeteringService.recordSessionStart(
                    userID: userID,
                    request: request,
                    response: response,
                    macAppVersion: version
                )
            } catch {
                AppLogger.daemon.error(
                    "computer_use_daemon_session_start_cloud_metering_failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func enqueueComputerUseActionMetering(
        request: ComputerUseInvokeRequest,
        response: ComputerUseInvokeResponse
    ) {
        guard let userID = Auth.auth().currentUser?.uid else { return }
        Task { @MainActor in
            do {
                try await computerUseCloudMeteringService.recordAction(
                    userID: userID,
                    invocation: request.invocation,
                    response: response
                )
            } catch {
                AppLogger.daemon.error(
                    "computer_use_daemon_action_cloud_metering_failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func enqueueComputerUseSessionEndMetering(
        request: ComputerUsePanicHaltRequest,
        response: ComputerUsePanicHaltResponse
    ) {
        guard let userID = Auth.auth().currentUser?.uid else { return }
        let reason = Self.computerUseEndReason(for: request.source)
        Task { @MainActor in
            do {
                try await computerUseCloudMeteringService.recordSessionEnd(
                    userID: userID,
                    sessionID: response.sessionId,
                    endedAt: response.endedAt,
                    reason: reason,
                    state: nil,
                    auditHeadHashHex: response.auditHeadHashHex
                )
            } catch {
                AppLogger.daemon.error(
                    "computer_use_daemon_session_end_cloud_metering_failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private static func computerUseEndReason(for rawSource: String) -> ComputerUseEndReason {
        switch ComputerUsePanicSource(rawValue: rawSource) {
        case .hotkey: return .panicHotkey
        case .phoneGesture: return .panicPhoneGesture
        case .macLock: return .panicMacLock
        case .remoteConfig: return .panicRemoteConfig
        case .accessibilityRevoked: return .panicAccessibilityRevoked
        case .stalled: return .timeout
        case .revoked: return .entitlementLost
        case nil: return .error
        }
    }
}
