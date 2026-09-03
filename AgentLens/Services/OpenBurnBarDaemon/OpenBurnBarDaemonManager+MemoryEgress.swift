import Foundation
import OpenBurnBarKernel

// MARK: - Memory Pro: policy hand-off to the daemon

extension OpenBurnBarDaemonManager {
    /// Hand the consented Memory Pro policy to the daemon by read-modify-writing
    /// the provider-config snapshot. Health-guarded like `setRouterMode`: an
    /// unreachable daemon skips the write and names it in `lastError`.
    ///
    /// - Parameter onlyIfChanged: skip the write when the daemon already holds
    ///   the same policy (ignoring `updatedAt`) — used at launch.
    func updateMemoryEgressPolicy(onlyIfChanged: Bool = false) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before the memory cloud-models policy can be updated."
                return
            }
        }

        let policy = settingsManager.memoryEgressPolicy()
        let socketURL = paths.socketURL
        let requestConfig = dependencies.requestConfig
        let updateConfig = dependencies.updateConfig
        do {
            var snapshot = try await daemonRPC {
                try requestConfig(socketURL)
            }
            if onlyIfChanged, Self.memoryEgressPoliciesMatch(snapshot.memoryEgress, policy) {
                return
            }
            snapshot.memoryEgress = policy
            let snapshotToWrite = snapshot
            _ = try await daemonRPC {
                try updateConfig(socketURL, snapshotToWrite)
            }
            lastError = nil
            AppLogger.daemon.info(
                "memory_cloud_models_policy_handed_off",
                metadata: [
                    "enabled": policy.enabled ? "true" : "false",
                    "providers": policy.consentedProviderIDs.joined(separator: ","),
                    "cli": policy.consentedCLIProviderIDs.joined(separator: ","),
                    "noRetention": policy.requireNoRetention ? "true" : "false"
                ]
            )
        } catch {
            lastError = "Memory cloud-models policy hand-off failed: \(error.localizedDescription)"
        }
    }

    /// Everything but `updatedAt`.
    static func memoryEgressPoliciesMatch(_ lhs: BurnBarMemoryEgressPolicy, _ rhs: BurnBarMemoryEgressPolicy) -> Bool {
        var left = lhs
        var right = rhs
        left.updatedAt = nil
        right.updatedAt = nil
        return left == right
    }

    /// Coalesce bursts of settings changes into one hand-off (500 ms).
    func scheduleMemoryEgressPolicyHandoff() {
        memoryEgressHandoffTask?.cancel()
        memoryEgressHandoffTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return  // cancelled: a newer change superseded this hand-off
            }
            guard let self else { return }
            await self.updateMemoryEgressPolicy()
        }
    }

    /// Wire the Memory Pro observers once (first attach), refresh the daemon's
    /// membership cache, and reconcile the policy the daemon holds with the
    /// member's settings.
    func startMemoryProConcierge() async {
        if memoryProObservers.isEmpty {
            let center = NotificationCenter.default
            for name in [Notification.Name.memoryCloudModelsPolicyDidChange, .memoryCloudModelsRemoteConfigKillSwitchDidFire] {
                memoryProObservers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.scheduleMemoryEgressPolicyHandoff() }
                    }
                )
            }
            memoryProObservers.append(
                center.addObserver(forName: .macCloudEntitlementDidChange, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.refreshDaemonMembershipCache(reason: "entitlement-change") }
                }
            )
            registerMembershipRefreshCadence()
        }
        await refreshDaemonMembershipCache(reason: "launch")
        await updateMemoryEgressPolicy(onlyIfChanged: true)
    }
}
