import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

struct CLIProfileStreamAttempt: Sendable {
    let profileID: String
    let executable: String
    let environmentOverrides: [String: String]
    let workingDirectory: URL?
}

final class CLIProfileStreamFailoverRunner: Sendable {
    typealias StreamLauncher = @Sendable (
        _ attempt: CLIProfileStreamAttempt,
        _ prompt: String,
        _ model: String,
        _ capabilityGrant: AgentCapabilityGrant?,
        _ continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async -> Void

    private let runtime: CLIBridgeStreamRuntimeCoordinator
    private let profileStore: any SwitcherProfileStoreAdapter
    private let fallbackPlanner: any CLIFallbackPlanning
    private let streamLauncher: StreamLauncher

    init(
        runtime: CLIBridgeStreamRuntimeCoordinator,
        profileStore: any SwitcherProfileStoreAdapter,
        fallbackPlanner: any CLIFallbackPlanning,
        streamLauncher: StreamLauncher? = nil
    ) {
        self.runtime = runtime
        self.profileStore = profileStore
        self.fallbackPlanner = fallbackPlanner
        self.streamLauncher = streamLauncher ?? { attempt, prompt, model, capabilityGrant, continuation in
            await CLIProcessStreamRunner(runtime: runtime).runCodex(
                executable: attempt.executable,
                prompt: prompt,
                model: model,
                workspaceDirectory: attempt.workingDirectory,
                capabilityGrant: capabilityGrant,
                environmentOverrides: attempt.environmentOverrides,
                // T-TOOL-03: mid-run grant poll also covers the failover lane.
                grantStillActive: CLIBridge.spawnedCLIGrantPoll(for: capabilityGrant),
                continuation: continuation
            )
        }
    }

    func streamCodex(
        requestedProfile: SwitcherProfileRecord,
        prompt: String,
        model: String,
        workspaceDirectory: URL?,
        capabilityGrant: AgentCapabilityGrant?
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                await runCodexWithFailover(
                    requestedProfile: requestedProfile,
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [runtime] _ in
                task.cancel()
                Task {
                    await runtime.cancelAll()
                }
            }
        }
    }

    private func runCodexWithFailover(
        requestedProfile: SwitcherProfileRecord,
        prompt: String,
        model: String,
        workspaceDirectory: URL?,
        capabilityGrant: AgentCapabilityGrant?,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        let allProfiles = profileStore.fetchAllProfiles()
        let plannerCandidates = await fallbackPlanner.orderedCandidates(
            for: requestedProfile,
            allProfiles: allProfiles
        )
        let candidates = prioritizedCandidates(
            requestedProfile: requestedProfile,
            plannerCandidates: plannerCandidates
        )

        var lastQuotaDetail: String?
        var lastError: Error?

        for candidate in candidates {
            do {
                try Task.checkCancellation()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            switch await fallbackPlanner.eligibility(for: candidate) {
            case .eligible:
                break
            case .quotaExhausted(let reason):
                lastQuotaDetail = reason
                continue
            case .ineligible(let reason):
                lastError = CLIBridgeError.codexEvent(reason)
                if candidate.id == requestedProfile.id {
                    continuation.finish(throwing: lastError)
                    return
                }
                continue
            }

            let attempt: CLIProfileStreamAttempt
            do {
                attempt = try buildCodexAttempt(
                    for: candidate,
                    workspaceDirectory: workspaceDirectory
                )
            } catch {
                lastError = error
                if candidate.id == requestedProfile.id {
                    continuation.finish(throwing: error)
                    return
                }
                continue
            }

            var emittedReplayUnsafeEvent = false
            var provisionalEvents: [CLIChatStreamEvent] = []
            do {
                let stream = stream(for: attempt, prompt: prompt, model: model, capabilityGrant: capabilityGrant)
                for try await event in stream {
                    if Self.blocksFailoverReplay(event) {
                        flush(provisionalEvents, to: continuation)
                        provisionalEvents.removeAll()
                        emittedReplayUnsafeEvent = true
                        continuation.yield(event)
                    } else if emittedReplayUnsafeEvent {
                        continuation.yield(event)
                    } else {
                        provisionalEvents.append(event)
                    }
                }

                flush(provisionalEvents, to: continuation)
                clearQuotaExhaustion(for: candidate)
                if candidate.id != requestedProfile.id {
                    profileStore.setActiveProfileID(candidate.id, for: ProviderID.codex)
                }
                continuation.finish()
                return
            } catch CLIBridgeError.quotaExhausted(let detail) where !emittedReplayUnsafeEvent {
                persistQuotaExhaustion(for: candidate, detail: detail)
                lastQuotaDetail = detail
                continue
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }

        if let lastQuotaDetail {
            continuation.finish(throwing: CLIBridgeError.quotaExhausted(lastQuotaDetail))
        } else {
            continuation.finish(
                throwing: lastError
                    ?? CLIBridgeError.codexEvent("No eligible Codex account profiles are available for failover.")
            )
        }
    }

    private func stream(
        for attempt: CLIProfileStreamAttempt,
        prompt: String,
        model: String,
        capabilityGrant: AgentCapabilityGrant?
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let launcher = streamLauncher
            Task.detached {
                await launcher(attempt, prompt, model, capabilityGrant, continuation)
            }
        }
    }

    private static func blocksFailoverReplay(_ event: CLIChatStreamEvent) -> Bool {
        switch event {
        case .text(let chunk):
            return chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .toolUse(let name, let detail):
            return !(name == "Codex" && detail == "Thinking…")
        case .toolResult:
            return true
        case .usage:
            return false
        }
    }

    private func flush(
        _ events: [CLIChatStreamEvent],
        to continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) {
        for event in events {
            continuation.yield(event)
        }
    }

    private func prioritizedCandidates(
        requestedProfile: SwitcherProfileRecord,
        plannerCandidates: [SwitcherProfileRecord]
    ) -> [SwitcherProfileRecord] {
        var seen = Set<String>()
        var ordered: [SwitcherProfileRecord] = []

        for candidate in [requestedProfile] + plannerCandidates where seen.insert(candidate.id).inserted {
            ordered.append(candidate)
        }

        return ordered
    }

    private func buildCodexAttempt(
        for profile: SwitcherProfileRecord,
        workspaceDirectory: URL?
    ) throws -> CLIProfileStreamAttempt {
        guard profile.targetKind == .cli else {
            throw CLILaunchError.profileKindMismatch(expected: .cli, actual: profile.targetKind)
        }
        guard profile.cliType == .codex else {
            throw CLILaunchError.profileTypeMismatch(expected: .codex, actual: profile.cliType)
        }

        switch CLILaunchAdapter.buildCLILaunch(profile: profile) {
        case .failure(let error):
            throw error
        case .success(let config):
            let profileWorkingDirectory = config.workingDirectory
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            return CLIProfileStreamAttempt(
                profileID: profile.id,
                executable: config.executable.path,
                environmentOverrides: config.env,
                workingDirectory: workspaceDirectory ?? profileWorkingDirectory
            )
        }
    }

    private func persistQuotaExhaustion(for profile: SwitcherProfileRecord, detail: String) {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType else {
            return
        }

        let safeDetail = CLILaunchRedactor.redactSensitiveData(detail)
        let now = Date()
        let existingMetadata = profile.cliMetadata ?? SwitcherCLIProfileMetadata()
        let updatedProfile = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: existingMetadata.configDirectory,
                accountDescription: existingMetadata.accountDescription,
                providerID: existingMetadata.providerID,
                runtimeAccountID: existingMetadata.runtimeAccountID,
                subscriptionTierID: existingMetadata.subscriptionTierID,
                modelCapabilityClassID: existingMetadata.modelCapabilityClassID,
                linkedHarnessIDs: existingMetadata.linkedHarnessIDs,
                neverAutoSwitch: existingMetadata.neverAutoSwitch,
                lastQuotaExhaustedAt: now,
                exhaustedUntil: CLIQuotaExhaustionClassifier.exhaustionWindowEnd(from: safeDetail, now: now),
                lastQuotaExhaustionDetail: safeDetail,
                isDisabled: existingMetadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt,
            updatedAt: Date()
        )

        profileStore.updateProfile(updatedProfile)
    }

    private func clearQuotaExhaustion(for profile: SwitcherProfileRecord) {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType,
              let existingMetadata = profile.cliMetadata,
              existingMetadata.lastQuotaExhaustedAt != nil
                || existingMetadata.exhaustedUntil != nil
                || existingMetadata.lastQuotaExhaustionDetail != nil else {
            return
        }

        let updatedProfile = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: existingMetadata.configDirectory,
                accountDescription: existingMetadata.accountDescription,
                providerID: existingMetadata.providerID,
                runtimeAccountID: existingMetadata.runtimeAccountID,
                subscriptionTierID: existingMetadata.subscriptionTierID,
                modelCapabilityClassID: existingMetadata.modelCapabilityClassID,
                linkedHarnessIDs: existingMetadata.linkedHarnessIDs,
                neverAutoSwitch: existingMetadata.neverAutoSwitch,
                isDisabled: existingMetadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt,
            updatedAt: Date()
        )

        profileStore.updateProfile(updatedProfile)
    }

}

final class ProductionSwitcherProfileStoreAdapter: SwitcherProfileStoreAdapter, Sendable {
    private let store: SwitcherProfileStore

    init(store: SwitcherProfileStore) {
        self.store = store
    }

    func fetchProfile(id: String) -> SwitcherProfileRecord? {
        try? store.fetchProfile(id: id)
    }

    func fetchAllProfiles() -> [SwitcherProfileRecord] {
        (try? store.fetchAllProfiles()) ?? []
    }

    func fetchActiveProfileID() -> String? {
        try? store.fetchActiveProfileState().activeProfileID
    }

    func fetchActiveProfileID(for providerID: ProviderID) -> String? {
        try? store.fetchActiveProfileID(for: providerID)
    }

    func setActiveProfileID(_ profileID: String?) {
        try? store.setActiveProfile(profileID)
    }

    func setActiveProfileID(_ profileID: String?, for providerID: ProviderID) {
        try? store.setActiveProfile(profileID, for: providerID)
    }

    func updateProfile(_ profile: SwitcherProfileRecord) {
        _ = try? store.update(profile)
    }
}
