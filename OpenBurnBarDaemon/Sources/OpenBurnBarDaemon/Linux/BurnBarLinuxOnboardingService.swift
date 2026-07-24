import OpenBurnBarEngine
import OpenBurnBarLinuxSecurity
import Foundation

public enum BurnBarLinuxOnboardingError: Error, LocalizedError, Equatable {
    case invalidAction(step: BurnBarLinuxOnboardingStepID, action: BurnBarLinuxOnboardingAction)
    case stepOutOfOrder(
        expected: BurnBarLinuxOnboardingStepID,
        requested: BurnBarLinuxOnboardingStepID
    )
    case invalidPrivacyChoices
    case invalidPersistedState(String)
    case probeUnavailable(step: BurnBarLinuxOnboardingStepID, detail: String)
    case secretStoreUnavailable(String)
    case providerPathsUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAction(let step, let action):
            return "Onboarding action \(action.rawValue) is not valid for \(step.rawValue)."
        case .stepOutOfOrder(let expected, let requested):
            return "Onboarding step \(requested.rawValue) cannot run while \(expected.rawValue) is active."
        case .invalidPrivacyChoices:
            return "Choose both telemetry and cloud-sync preferences before continuing."
        case .invalidPersistedState(let detail):
            return "The daemon-owned onboarding state is invalid: \(detail)"
        case .probeUnavailable(let step, let detail):
            return "The \(step.rawValue) onboarding probe is unavailable: \(detail)"
        case .secretStoreUnavailable(let detail):
            return "Secret Service verification failed: \(detail)"
        case .providerPathsUnavailable(let detail):
            return "Linux storage path verification failed: \(detail)"
        }
    }
}

public actor BurnBarLinuxOnboardingService {
    public typealias Probe = @Sendable () async throws -> String

    public static let orderedSteps: [(BurnBarLinuxOnboardingStepID, BurnBarLinuxOnboardingRequirement)] = [
        (.daemon, .required),
        (.secretStore, .required),
        (.providerPaths, .required),
        (.cloudIdentity, .optional),
        (.portalInput, .optional),
        (.tray, .optional),
        (.updates, .optional),
        (.privacy, .required)
    ]

    private let stateURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let daemonProbe: Probe
    private let secretStoreProbe: Probe
    private let providerPathsProbe: Probe
    private let optionalProbes: [BurnBarLinuxOnboardingStepID: Probe]
    private let configStore: BurnBarConfigStore?

    public init(
        stateURL: URL = BurnBarDaemonPaths.defaultLinuxOnboardingStateURL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        daemonProbe: @escaping Probe = {
            "The daemon accepted and verified this authenticated onboarding RPC."
        },
        secretStoreProbe: @escaping Probe = BurnBarLinuxOnboardingService.verifyProductionSecretStore,
        providerCatalogCount: Int = BurnBarCatalogLoader.bundledCatalog.providers.count,
        providerPathsProbe: Probe? = nil,
        cloudIdentityProbe: Probe? = nil,
        portalInputProbe: Probe? = nil,
        trayProbe: Probe? = nil,
        updatesProbe: Probe? = nil,
        configStore: BurnBarConfigStore? = nil
    ) {
        self.stateURL = stateURL
        self.fileManager = fileManager
        self.now = now
        self.daemonProbe = daemonProbe
        self.secretStoreProbe = secretStoreProbe
        self.configStore = configStore
        var optionalProbes: [BurnBarLinuxOnboardingStepID: Probe] = [:]
        optionalProbes[.cloudIdentity] = cloudIdentityProbe ?? {
            throw BurnBarLinuxOnboardingError.probeUnavailable(
                step: .cloudIdentity,
                detail: "native cloud sign-in must be completed from the account flow"
            )
        }
        optionalProbes[.portalInput] = portalInputProbe ?? {
            throw BurnBarLinuxOnboardingError.probeUnavailable(
                step: .portalInput,
                detail: "portal consent is granted only by a live desktop session"
            )
        }
        optionalProbes[.tray] = trayProbe ?? {
            throw BurnBarLinuxOnboardingError.probeUnavailable(
                step: .tray,
                detail: "tray availability must be confirmed by the native shell"
            )
        }
        optionalProbes[.updates] = updatesProbe ?? {
            throw BurnBarLinuxOnboardingError.probeUnavailable(
                step: .updates,
                detail: "a signed package channel is required before update verification"
            )
        }
        self.optionalProbes = optionalProbes
        self.providerPathsProbe = providerPathsProbe ?? {
            let detail = try BurnBarLinuxOnboardingService.verifyProviderData(
                at: stateURL.deletingLastPathComponent(),
                providerCount: providerCatalogCount,
                fileManager: fileManager
            )
            guard let configStore else {
                return detail
            }
            let routeProviderIDs = try await configStore.onboardingRoutingProviderIDs()
            guard !routeProviderIDs.isEmpty else {
                throw BurnBarLinuxOnboardingError.providerPathsUnavailable(
                    "No enabled routing provider has a local endpoint or readable credential; connect a provider and retry."
                )
            }
            return "\(detail) Daemon routing is ready through \(routeProviderIDs.joined(separator: ", "))."
        }
    }

    public func snapshot() throws -> BurnBarLinuxOnboardingSnapshot {
        try loadSnapshot()
    }

    public func perform(
        _ request: BurnBarLinuxOnboardingActionRequest
    ) async throws -> BurnBarLinuxOnboardingSnapshot {
        var snapshot = try loadSnapshot()
        guard let index = snapshot.steps.firstIndex(where: { $0.id == request.stepID }) else {
            throw BurnBarLinuxOnboardingError.invalidPersistedState("missing step \(request.stepID.rawValue)")
        }

        if request.action == .navigate {
            let firstUnresolvedIndex = snapshot.steps.firstIndex(where: { !Self.isTerminal($0) })
                ?? snapshot.steps.index(before: snapshot.steps.endIndex)
            guard index <= firstUnresolvedIndex else {
                throw BurnBarLinuxOnboardingError.stepOutOfOrder(
                    expected: snapshot.steps[firstUnresolvedIndex].id,
                    requested: request.stepID
                )
            }
            snapshot = replacing(snapshot, currentStepID: request.stepID)
            try persist(snapshot)
            return snapshot
        }

        guard request.stepID == snapshot.currentStepID else {
            throw BurnBarLinuxOnboardingError.stepOutOfOrder(
                expected: snapshot.currentStepID,
                requested: request.stepID
            )
        }

        let step = snapshot.steps[index]
        var privacyChoices = snapshot.privacyChoices
        let updatedStep: BurnBarLinuxOnboardingStepSnapshot
        switch request.action {
        case .verify:
            let probe: Probe
            switch request.stepID {
            case .daemon:
                probe = daemonProbe
            case .secretStore:
                probe = secretStoreProbe
            case .providerPaths:
                probe = providerPathsProbe
            case .cloudIdentity, .portalInput, .tray, .updates:
                guard let optionalProbe = optionalProbes[request.stepID] else {
                    throw BurnBarLinuxOnboardingError.probeUnavailable(
                        step: request.stepID,
                        detail: "no daemon probe is registered"
                    )
                }
                probe = optionalProbe
            default:
                throw BurnBarLinuxOnboardingError.invalidAction(step: request.stepID, action: request.action)
            }
            do {
                let detail = try await probe()
                updatedStep = terminalStep(from: step, state: .verified, detail: detail)
            } catch {
                updatedStep = BurnBarLinuxOnboardingStepSnapshot(
                    id: step.id,
                    requirement: step.requirement,
                    state: .blocked,
                    attemptCount: step.attemptCount + 1,
                    detail: boundedErrorDetail(error),
                    verifiedAt: nil,
                    repairAction: Self.repairAction(for: step.id)
                )
            }
        case .acknowledge:
            guard step.requirement == .optional else {
                throw BurnBarLinuxOnboardingError.invalidAction(step: request.stepID, action: request.action)
            }
            updatedStep = terminalStep(
                from: step,
                state: .acknowledged,
                detail: "The Linux-specific limitation was explicitly acknowledged."
            )
        case .skip:
            guard step.requirement == .optional else {
                throw BurnBarLinuxOnboardingError.invalidAction(step: request.stepID, action: request.action)
            }
            updatedStep = terminalStep(
                from: step,
                state: .skipped,
                detail: "Optional setup was deferred by the user."
            )
        case .savePrivacyChoices:
            guard request.stepID == .privacy,
                  let telemetryEnabled = request.telemetryEnabled,
                  let cloudSyncEnabled = request.cloudSyncEnabled else {
                throw BurnBarLinuxOnboardingError.invalidPrivacyChoices
            }
            privacyChoices = BurnBarLinuxOnboardingPrivacyChoices(
                telemetryEnabled: telemetryEnabled,
                cloudSyncEnabled: cloudSyncEnabled
            )
            if let configStore {
                var config = try await configStore.snapshot()
                config.telemetryEnabled = telemetryEnabled
                config.privacyOptIn = telemetryEnabled
                config.cloudSyncEnabled = cloudSyncEnabled
                _ = try await configStore.replaceSnapshot(config)
            }
            updatedStep = terminalStep(
                from: step,
                state: .verified,
                detail: "Privacy choices were committed to daemon-owned state and read back."
            )
        case .navigate:
            preconditionFailure("Navigation is handled before step mutation.")
        }

        var steps = snapshot.steps
        steps[index] = updatedStep
        let completed = Self.isComplete(steps)
        let nextStepID = completed ? request.stepID : nextStep(after: index, in: steps)
        snapshot = BurnBarLinuxOnboardingSnapshot(
            revision: snapshot.revision + 1,
            currentStepID: updatedStep.state == .blocked ? request.stepID : nextStepID,
            steps: steps,
            privacyChoices: privacyChoices,
            completed: completed,
            updatedAt: timestamp()
        )
        try persist(snapshot)
        return try validated(snapshot)
    }

    public func reset() throws -> BurnBarLinuxOnboardingSnapshot {
        let snapshot = initialSnapshot(revision: (try? loadSnapshot().revision + 1) ?? 1)
        try persist(snapshot)
        return snapshot
    }

    public nonisolated static func isComplete(_ steps: [BurnBarLinuxOnboardingStepSnapshot]) -> Bool {
        steps.allSatisfy { step in
            switch step.requirement {
            case .required:
                step.state == .verified
            case .optional:
                step.state == .verified || step.state == .acknowledged || step.state == .skipped
            }
        }
    }

    private nonisolated static func isTerminal(_ step: BurnBarLinuxOnboardingStepSnapshot) -> Bool {
        switch step.requirement {
        case .required:
            step.state == .verified
        case .optional:
            step.state == .verified || step.state == .acknowledged || step.state == .skipped
        }
    }

    private nonisolated static func repairAction(
        for stepID: BurnBarLinuxOnboardingStepID
    ) -> BurnBarLinuxOnboardingRepairAction {
        switch stepID {
        case .daemon:
            return .startDaemon
        case .secretStore:
            return .unlockSecretStore
        case .providerPaths:
            return .repairProviderData
        case .cloudIdentity:
            return .signIn
        case .portalInput:
            return .grantPortal
        case .tray:
            return .enableTray
        case .updates:
            return .openUpdates
        case .privacy:
            return .choosePrivacy
        }
    }

    private func loadSnapshot() throws -> BurnBarLinuxOnboardingSnapshot {
        try rejectSymbolicStatePathComponents()
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return initialSnapshot(revision: 0)
        }
        do {
            let data = try Data(contentsOf: stateURL)
            return try validated(JSONDecoder().decode(BurnBarLinuxOnboardingSnapshot.self, from: data))
        } catch let error as BurnBarLinuxOnboardingError {
            throw error
        } catch {
            throw BurnBarLinuxOnboardingError.invalidPersistedState(boundedErrorDetail(error))
        }
    }

    private func validated(
        _ snapshot: BurnBarLinuxOnboardingSnapshot
    ) throws -> BurnBarLinuxOnboardingSnapshot {
        guard snapshot.schemaVersion == 1 else {
            throw BurnBarLinuxOnboardingError.invalidPersistedState(
                "unsupported schema version \(snapshot.schemaVersion)"
            )
        }
        let expected = Self.orderedSteps
        guard snapshot.steps.count == expected.count else {
            throw BurnBarLinuxOnboardingError.invalidPersistedState("unexpected step count")
        }
        for (step, expectedStep) in zip(snapshot.steps, expected) {
            guard step.id == expectedStep.0, step.requirement == expectedStep.1 else {
                throw BurnBarLinuxOnboardingError.invalidPersistedState("step order or requirement drift")
            }
            if step.requirement == .required,
               step.state == .acknowledged || step.state == .skipped {
                throw BurnBarLinuxOnboardingError.invalidPersistedState(
                    "required step \(step.id.rawValue) has an optional-only state"
                )
            }
        }
        guard snapshot.steps.contains(where: { $0.id == snapshot.currentStepID }) else {
            throw BurnBarLinuxOnboardingError.invalidPersistedState("current step is unknown")
        }
        if let firstUnresolvedIndex = snapshot.steps.firstIndex(where: { !Self.isTerminal($0) }),
           let currentIndex = snapshot.steps.firstIndex(where: { $0.id == snapshot.currentStepID }),
           currentIndex > firstUnresolvedIndex {
            throw BurnBarLinuxOnboardingError.invalidPersistedState(
                "current step is ahead of an unresolved prerequisite"
            )
        }
        if let firstUnresolvedIndex = snapshot.steps.firstIndex(where: { !Self.isTerminal($0) }),
           snapshot.steps[(firstUnresolvedIndex + 1)...].contains(where: { Self.isTerminal($0) }) {
            throw BurnBarLinuxOnboardingError.invalidPersistedState(
                "terminal step exists beyond an unresolved prerequisite"
            )
        }
        guard snapshot.completed == Self.isComplete(snapshot.steps) else {
            throw BurnBarLinuxOnboardingError.invalidPersistedState("completion invariant mismatch")
        }
        guard snapshot.steps.first(where: { $0.id == .privacy })?.state != .verified
                || snapshot.privacyChoices != nil else {
            throw BurnBarLinuxOnboardingError.invalidPersistedState("privacy verification is missing choices")
        }
        return snapshot
    }

    private func initialSnapshot(revision: Int) -> BurnBarLinuxOnboardingSnapshot {
        BurnBarLinuxOnboardingSnapshot(
            revision: revision,
            currentStepID: .daemon,
            steps: Self.orderedSteps.map {
                BurnBarLinuxOnboardingStepSnapshot(id: $0.0, requirement: $0.1)
            },
            completed: false,
            updatedAt: timestamp()
        )
    }

    private func terminalStep(
        from step: BurnBarLinuxOnboardingStepSnapshot,
        state: BurnBarLinuxOnboardingStepState,
        detail: String
    ) -> BurnBarLinuxOnboardingStepSnapshot {
        BurnBarLinuxOnboardingStepSnapshot(
            id: step.id,
            requirement: step.requirement,
            state: state,
            attemptCount: step.attemptCount + 1,
            detail: detail,
            verifiedAt: timestamp(),
            repairAction: nil
        )
    }

    private func nextStep(
        after index: Int,
        in steps: [BurnBarLinuxOnboardingStepSnapshot]
    ) -> BurnBarLinuxOnboardingStepID {
        guard index + 1 < steps.count else { return steps[index].id }
        return steps[index + 1].id
    }

    private func replacing(
        _ snapshot: BurnBarLinuxOnboardingSnapshot,
        currentStepID: BurnBarLinuxOnboardingStepID
    ) -> BurnBarLinuxOnboardingSnapshot {
        BurnBarLinuxOnboardingSnapshot(
            revision: snapshot.revision + 1,
            currentStepID: currentStepID,
            steps: snapshot.steps,
            privacyChoices: snapshot.privacyChoices,
            completed: snapshot.completed,
            updatedAt: timestamp()
        )
    }

    private func persist(_ snapshot: BurnBarLinuxOnboardingSnapshot) throws {
        try rejectSymbolicStatePathComponents()
        let stateDirectoryURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stateDirectoryURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: stateURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    /// Onboarding state is daemon-owned and must stay below the configured
    /// support directory.  Reject both existing symlinks and dangling links
    /// before reads or atomic replacement so a user-controlled path cannot
    /// redirect state outside the private 0700/0600 boundary.
    private func rejectSymbolicStatePathComponents() throws {
        let components: [(URL, String)] = [
            (stateURL.deletingLastPathComponent(), "state directory"),
            (stateURL, "state file")
        ]

        for (url, label) in components {
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let fileType = attributes[.type] as? FileAttributeType,
               fileType == .typeSymbolicLink {
                throw BurnBarLinuxOnboardingError.invalidPersistedState(
                    "onboarding \(label) must not be a symbolic link"
                )
            }

            // `attributesOfItem` may not report a dangling link as existing.
            // FileManager's destination lookup is link-specific and catches
            // that case without resolving the destination for any operation.
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw BurnBarLinuxOnboardingError.invalidPersistedState(
                    "onboarding \(label) must not be a symbolic link"
                )
            }
        }
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: now())
    }

    private func boundedErrorDetail(_ error: Error) -> String {
        String((error as? LocalizedError)?.errorDescription?.prefix(512)
            ?? error.localizedDescription.prefix(512))
    }

    public nonisolated static func verifyProductionSecretStore() throws -> String {
        #if os(Linux)
        return try verifyProductionSecretStore(using: LinuxSecretStoreFactory.production())
        #else
        throw BurnBarLinuxOnboardingError.secretStoreUnavailable(
            "native Secret Service verification requires Linux"
        )
        #endif
    }

    /// Runs the ephemeral production probe against an injected custodian so
    /// the same health-before-mutation contract is testable without touching
    /// a user's keyring. Production callers use the zero-argument overload.
    public nonisolated static func verifyProductionSecretStore(
        using custodian: LinuxSecretCustodian
    ) throws -> String {
        let probeID = "openburnbar-onboarding-\(UUID().uuidString)"
        let probeValue = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var lastError: Error?
        for backend in custodian.backends
            where backend.supportsMutations && backend.trustLevel.approvedForHighValueSecrets {
            var probeStored = false
            do {
                // Secret Service and KWallet can expose an executable command
                // while their session/keyring is locked. Health must succeed
                // before any write so onboarding never mutates a backend that
                // cannot be read back and cleaned up reliably.
                try backend.healthCheck()
                _ = try backend.storeSecret(
                    probeValue,
                    id: probeID,
                    secretClass: .providerCredential
                )
                probeStored = true
                let readback = try backend.readSecret(id: probeID, secretClass: .providerCredential)
                guard readback?.secret == probeValue else {
                    throw LinuxSecretStoreError.commandFailed(
                        backend: backend.backendName,
                        operation: "readback",
                        detail: "ephemeral verification value did not round-trip"
                    )
                }
                try backend.deleteSecret(id: probeID, secretClass: .providerCredential)
                probeStored = false
                return "\(backend.backendName) passed an ephemeral write/read/delete verification."
            } catch {
                if probeStored {
                    do {
                        // A successful write must never be allowed to escape
                        // onboarding when cleanup cannot be confirmed. Retry
                        // once after a readback/delete failure, then fail
                        // closed instead of falling through to another backend
                        // with an orphaned probe secret.
                        try backend.deleteSecret(id: probeID, secretClass: .providerCredential)
                    } catch {
                        throw BurnBarLinuxOnboardingError.secretStoreUnavailable(
                            "\(backend.backendName) could not delete its ephemeral verification value; onboarding remains blocked."
                        )
                    }
                }
                lastError = error
            }
        }
        let detail = lastError.map { String(describing: $0) }
            ?? "no writable approved Secret Service or KWallet backend is available"
        throw BurnBarLinuxOnboardingError.secretStoreUnavailable(detail)
    }

    public nonisolated static func verifyWritableDirectory(
        _ directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let probeURL = directoryURL.appendingPathComponent(
                ".onboarding-write-probe-\(UUID().uuidString)",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: probeURL) }
            try Data("openburnbar-path-probe".utf8).write(to: probeURL, options: [.atomic])
            guard try Data(contentsOf: probeURL) == Data("openburnbar-path-probe".utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try fileManager.removeItem(at: probeURL)
            return "Daemon support storage is writable at \(directoryURL.path)."
        } catch {
            throw BurnBarLinuxOnboardingError.providerPathsUnavailable(error.localizedDescription)
        }
    }

    /// Required first-data probe used by the packaged daemon. A writable XDG
    /// directory alone is not enough to complete onboarding: the bundled
    /// provider catalog must also be present so the first renderer read has a
    /// real data source.
    public nonisolated static func verifyProviderData(
        at directoryURL: URL,
        providerCount: Int,
        fileManager: FileManager = .default
    ) throws -> String {
        let pathDetail = try verifyWritableDirectory(directoryURL, fileManager: fileManager)
        guard providerCount > 0 else {
            throw BurnBarLinuxOnboardingError.providerPathsUnavailable(
                "The bundled provider catalog is empty; first-run data cannot be loaded."
            )
        }
        return "\(pathDetail) Bundled provider catalog loaded with \(providerCount) provider definitions."
    }
}
