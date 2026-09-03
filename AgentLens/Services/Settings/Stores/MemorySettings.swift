import Foundation
import OpenBurnBarCore

// MARK: - Memory Settings (user toggle + fleet kill switch, G4)

/// Persists the user-facing memory preferences. The Remote Config fleet kill
/// switch (`remoteConfigExtractionEnabled`) is not user-settable; it is written
/// by the `SettingsManager` Remote Config refresh and defaults to allowed.
@Observable
@MainActor
final class MemorySettings {
    private let persistence: SettingsPersistenceCoordinator

    /// User toggle: automatic extraction on terminal assistant commit (default ON).
    var automaticExtraction: Bool = true {
        didSet {
            persistence.set(automaticExtraction, forKey: "memoryAutomaticExtraction")
            propagateExtractionGate()
        }
    }

    /// Opt-in sub-toggle: high-recall per-reply (default OFF).
    var highRecallPerReply: Bool = false {
        didSet { persistence.set(highRecallPerReply, forKey: "memoryHighRecallPerReply") }
    }

    /// Opt-in: replicate **approved** sealed memory facts to the user's cloud
    /// vault (default OFF — PR-E2 / residual decision §5.5). Cloud egress of
    /// derived memory is consent-gated independently of local extraction:
    /// enabling local extraction does not imply consent to upload memory off the
    /// device, even sealed. When false, `MemoryCloudSyncDomain.sync()` early-exits
    /// before any candidate is read or any Firestore handle is touched, so there
    /// is zero cloud egress out of the box. This switch is additionally clamped by
    /// the fleet ceiling (`remoteConfigExtractionEnabled`) at the sync boundary.
    var approvedCloudBackupEnabled: Bool = false {
        didSet { persistence.set(approvedCloudBackupEnabled, forKey: "memoryApprovedCloudBackupEnabled") }
    }

    /// Firebase Remote Config `memory_extraction_enabled` (default true). Not
    /// user-settable; the fleet kill switch sets this false to halt extraction
    /// instantly. Fetch transport errors preserve extraction only when the
    /// active cached config is not already false.
    var remoteConfigExtractionEnabled: Bool = true {
        didSet {
            propagateExtractionGate()
        }
    }

    /// User consent (gate G0, default OFF): the user has affirmatively opted in to
    /// chat-memory extraction via the first-run consent prompt. Until this is true
    /// no transcript is read, no LLM extraction runs, and no `agent_memories` row is
    /// written — it is ANDed into `MemoryExtractionGate`, so it gates the whole loop
    /// (extraction AND recall). Granting consent implies the prompt has been shown.
    var consentGranted: Bool = false {
        didSet {
            persistence.set(consentGranted, forKey: "memoryConsentGranted")
            if consentGranted { consentShown = true }
            propagateExtractionGate()
            propagateCloudModelsGate()
        }
    }

    /// Whether the first-run memory consent prompt has been presented (so it is not
    /// shown again). Set when consent is granted, or when the user declines.
    var consentShown: Bool = false {
        didSet { persistence.set(consentShown, forKey: "memoryConsentShown") }
    }

    // MARK: Memory Pro cloud models (opt-in, blind)

    /// User toggle: let Memory Pro use cloud / big models through the daemon
    /// (default OFF). ANDed with base memory consent and the fleet switch in
    /// `MemoryCloudModelsGate`; the daemon enforces the resulting policy on
    /// every request, BurnBar never receives memory data. Turning it on implies
    /// the cloud-models consent sheet has been shown.
    var cloudModelsEnabled: Bool = false {
        didSet {
            persistence.set(cloudModelsEnabled, forKey: "memoryCloudModelsEnabled")
            if cloudModelsEnabled { cloudModelsConsentShown = true }
            propagateCloudModelsGate()
        }
    }

    /// Whether the cloud-models consent sheet has been presented.
    var cloudModelsConsentShown: Bool = false {
        didSet { persistence.set(cloudModelsConsentShown, forKey: "memoryCloudModelsConsentShown") }
    }

    /// Providers the member consented to, in the order they were chosen.
    /// Persisted as a JSON array of raw ids (`MemoryCloudProviderID`).
    var cloudModelsConsentedProviderIDs: [MemoryCloudProviderID] = [] {
        didSet {
            persistence.set(
                MemoryCloudProviderID.encodeList(cloudModelsConsentedProviderIDs),
                forKey: "memoryCloudModelsConsentedProvidersJSON"
            )
            propagateCloudModelsGate()
        }
    }

    /// Only route to providers that promise no retention (default ON). The
    /// daemon refuses provider-policy routes while this is on.
    var cloudModelsRequireNoRetention: Bool = true {
        didSet {
            persistence.set(cloudModelsRequireNoRetention, forKey: "memoryCloudModelsRequireNoRetention")
            propagateCloudModelsGate()
        }
    }

    /// Daily USD cap the daemon enforces for memory purposes (default 2.00),
    /// clamped to `0...BurnBarMemoryEgressPolicy.maxDailyCapUSD`. Stored with
    /// a sentinel so an explicit 0 survives a relaunch.
    var cloudModelsDailyCapUSD: Double = 2.0 {
        didSet {
            let clamped = Self.clampCloudModelsDailyCap(cloudModelsDailyCapUSD)
            if clamped != cloudModelsDailyCapUSD {
                cloudModelsDailyCapUSD = clamped
            }
            persistence.set(clamped, forKey: "memoryCloudModelsDailyCapUSD")
            persistence.set(true, forKey: "hasMemoryCloudModelsDailyCapUSD")
            propagateCloudModelsGate()
        }
    }

    /// Firebase Remote Config `memory_cloud_models_enabled` (default true). Not
    /// user-settable and not persisted; a fleet flip to false closes the gate
    /// instantly and the daemon is handed the policy disabled.
    var remoteConfigCloudModelsEnabled: Bool = true {
        didSet { propagateCloudModelsGate() }
    }

    static func clampCloudModelsDailyCap(_ value: Double) -> Double {
        guard value.isFinite else { return 2.0 }
        return min(max(value, 0), BurnBarMemoryEgressPolicy.maxDailyCapUSD)
    }

    /// The effective cloud-models gate (consent AND toggle AND fleet switch).
    var cloudModelsGateEnabled: Bool {
        MemoryCloudModelsGate.isEnabled(
            consentGranted: consentGranted,
            cloudModelsEnabled: cloudModelsEnabled,
            remoteConfigEnabled: remoteConfigCloudModelsEnabled
        )
    }

    // MARK: Usage memory (passive memory from Safari asks + agent session logs)

    /// User consent to usage-memory extraction (default OFF). This is the sibling
    /// of chat's `consentGranted` for the usage-memory feature: until the user
    /// affirmatively opts in, no Safari ask or agent session log is read and no
    /// usage memory is derived — it is ANDed into `UsageMemoryExtractionGate`, so
    /// the whole usage loop is dormant out of the box. Granting consent implies
    /// the prompt has been shown.
    var usageMemoryConsentGranted: Bool = false {
        didSet {
            persistence.set(usageMemoryConsentGranted, forKey: "usageMemoryConsentGranted")
            if usageMemoryConsentGranted { usageMemoryConsentShown = true }
            propagateUsageGates()
        }
    }

    /// Whether the usage-memory consent prompt has been presented (so it is not
    /// shown again). Set when consent is granted, or when the user declines.
    var usageMemoryConsentShown: Bool = false {
        didSet { persistence.set(usageMemoryConsentShown, forKey: "usageMemoryConsentShown") }
    }

    /// Separate opt-in for CLOUD curation of usage memory (default OFF). Local
    /// extraction consent does not imply consent to send usage-derived material
    /// to a cloud model; this is ANDed into `UsageMemoryCloudGate` together with
    /// a cloud model placement, so cloud curation stays off unless the user both
    /// consents and points placement at a cloud model.
    var usageMemoryCloudCurationConsentGranted: Bool = false {
        didSet {
            persistence.set(
                usageMemoryCloudCurationConsentGranted,
                forKey: "usageMemoryCloudCurationConsentGranted"
            )
        }
    }

    /// Where the usage-memory curation model runs (default `.local`). Only a
    /// cloud placement (`.cloudText` / `.burnbarCloud`) can satisfy
    /// `UsageMemoryCloudGate`; the default keeps curation fully on-device.
    var usageMemoryModelPlacement: UsageMemoryModelPlacement = .local {
        didSet { persistence.set(usageMemoryModelPlacement, forKey: "usageMemoryModelPlacement") }
    }

    /// Source toggle: derive usage memory from Safari asks (default ON — inert
    /// until the consent gate opens).
    var usageMemorySourceSafariAsksEnabled: Bool = true {
        didSet {
            persistence.set(usageMemorySourceSafariAsksEnabled, forKey: "usageMemorySourceSafariAsksEnabled")
        }
    }

    /// Source toggle: derive usage memory from agent session logs (default ON —
    /// inert until the consent gate opens).
    var usageMemorySourceAgentSessionsEnabled: Bool = true {
        didSet {
            persistence.set(usageMemorySourceAgentSessionsEnabled, forKey: "usageMemorySourceAgentSessionsEnabled")
        }
    }

    /// Firebase Remote Config `memory_usage_extraction_enabled` (default true).
    /// Not user-settable and not persisted; the fleet kill switch sets this false
    /// to halt usage extraction instantly. Same transport posture as the chat
    /// switch: fetch errors preserve extraction only when the active cached
    /// config is not already false.
    ///
    /// This default is only meaningful once `hasResolvedUsageRemoteConfig` is
    /// true — until then the usage lanes are held CLOSED regardless, so the
    /// optimistic `true` can never open a lane ahead of the cached fleet value.
    var remoteConfigUsageExtractionEnabled: Bool = true {
        didSet { propagateUsageGates() }
    }

    /// Firebase Remote Config `memory_usage_authority_writes_enabled` (default
    /// true). Not user-settable and not persisted; a fleet flip to false halts
    /// durable authority writes from the usage pipeline while leaving extraction
    /// gating untouched. Same "inert until resolved" caveat as above.
    var remoteConfigUsageAuthorityWritesEnabled: Bool = true {
        didSet { propagateUsageGates() }
    }

    /// Whether a Remote Config value — the **active cached** config at init, or a
    /// freshly fetched one — has been applied to the two usage fleet switches.
    ///
    /// WHY THIS EXISTS (U1 review, thread `PRRT_kwDORtgQYs6ZgTEJ`): the two RC
    /// fields above are session-scoped and default to the optimistic `true`. A
    /// returning user whose `usageMemoryConsentGranted` is already `true` would
    /// therefore propagate an OPEN extraction lane at init and hold it open until
    /// the asynchronous `fetchAndActivate` landed — ignoring a fleet kill that was
    /// already sitting in Firebase's cache on disk. Rather than trusting that no
    /// worker registers inside that window, the gates are structurally held CLOSED
    /// until an RC value has actually been applied: this flag is ANDed into both
    /// `UsageMemoryExtractionGate` and `UsageMemoryAuthorityWriteGate`.
    ///
    /// Not persisted: every launch re-resolves, so a relaunch always starts closed.
    private(set) var hasResolvedUsageRemoteConfig: Bool = false {
        didSet { propagateUsageGates() }
    }

    /// Apply a resolved Remote Config snapshot to both usage fleet switches and
    /// mark the lanes resolved. This is the ONLY path that opens the usage lanes:
    /// the individual `remoteConfig…` setters deliberately do not resolve, so a
    /// partial write can never promote a defaulted `true` into an open lane.
    ///
    /// Called with the active **cached** config before the network fetch, and
    /// again with the fetched values after it activates.
    func applyUsageRemoteConfig(extractionEnabled: Bool, authorityWritesEnabled: Bool) {
        remoteConfigUsageExtractionEnabled = extractionEnabled
        remoteConfigUsageAuthorityWritesEnabled = authorityWritesEnabled
        hasResolvedUsageRemoteConfig = true
    }

    /// - Parameter usageRemoteConfigSeed: the **active cached** usage Remote Config
    ///   values, read synchronously (no network). Returning `nil` means "no fleet
    ///   channel resolved yet" and leaves both usage lanes CLOSED until
    ///   `applyUsageRemoteConfig` lands. `SettingsManager` supplies Firebase's
    ///   activated cache here so a cached kill is honored before any gate opens.
    init(
        persistence: SettingsPersistenceCoordinator,
        usageRemoteConfigSeed: () -> UsageMemoryRemoteConfigSnapshot? = { nil }
    ) {
        self.persistence = persistence
        if persistence.objectExists(forKey: "memoryAutomaticExtraction") {
            self.automaticExtraction = persistence.bool(forKey: "memoryAutomaticExtraction")
        }
        if persistence.objectExists(forKey: "memoryHighRecallPerReply") {
            self.highRecallPerReply = persistence.bool(forKey: "memoryHighRecallPerReply")
        }
        if persistence.objectExists(forKey: "memoryApprovedCloudBackupEnabled") {
            self.approvedCloudBackupEnabled = persistence.bool(forKey: "memoryApprovedCloudBackupEnabled")
        }
        // Load `consentShown` before `consentGranted` so the granted-didSet's
        // implicit `consentShown = true` never races a stale persisted value.
        if persistence.objectExists(forKey: "memoryConsentShown") {
            self.consentShown = persistence.bool(forKey: "memoryConsentShown")
        }
        if persistence.objectExists(forKey: "memoryConsentGranted") {
            self.consentGranted = persistence.bool(forKey: "memoryConsentGranted")
        }
        // Memory Pro cloud models. Shown before enabled, same ordering rule.
        if persistence.objectExists(forKey: "memoryCloudModelsConsentShown") {
            self.cloudModelsConsentShown = persistence.bool(forKey: "memoryCloudModelsConsentShown")
        }
        if persistence.objectExists(forKey: "memoryCloudModelsEnabled") {
            self.cloudModelsEnabled = persistence.bool(forKey: "memoryCloudModelsEnabled")
        }
        if persistence.objectExists(forKey: "memoryCloudModelsConsentedProvidersJSON") {
            self.cloudModelsConsentedProviderIDs = MemoryCloudProviderID.decodeList(
                persistence.string(forKey: "memoryCloudModelsConsentedProvidersJSON", defaultValue: "[]")
            )
        }
        if persistence.objectExists(forKey: "memoryCloudModelsRequireNoRetention") {
            self.cloudModelsRequireNoRetention = persistence.bool(forKey: "memoryCloudModelsRequireNoRetention")
        }
        if persistence.bool(forKey: "hasMemoryCloudModelsDailyCapUSD") {
            self.cloudModelsDailyCapUSD = Self.clampCloudModelsDailyCap(
                persistence.double(forKey: "memoryCloudModelsDailyCapUSD", defaultValue: 2.0)
            )
        }
        // Usage memory. Load `usageMemoryConsentShown` before
        // `usageMemoryConsentGranted` for the same shown/granted ordering reason
        // as chat consent above.
        if persistence.objectExists(forKey: "usageMemoryConsentShown") {
            self.usageMemoryConsentShown = persistence.bool(forKey: "usageMemoryConsentShown")
        }
        if persistence.objectExists(forKey: "usageMemoryConsentGranted") {
            self.usageMemoryConsentGranted = persistence.bool(forKey: "usageMemoryConsentGranted")
        }
        if persistence.objectExists(forKey: "usageMemoryCloudCurationConsentGranted") {
            self.usageMemoryCloudCurationConsentGranted = persistence.bool(
                forKey: "usageMemoryCloudCurationConsentGranted"
            )
        }
        self.usageMemoryModelPlacement = persistence.rawRepresentable(
            forKey: "usageMemoryModelPlacement",
            defaultValue: .local
        )
        if persistence.objectExists(forKey: "usageMemorySourceSafariAsksEnabled") {
            self.usageMemorySourceSafariAsksEnabled = persistence.bool(forKey: "usageMemorySourceSafariAsksEnabled")
        }
        if persistence.objectExists(forKey: "usageMemorySourceAgentSessionsEnabled") {
            self.usageMemorySourceAgentSessionsEnabled = persistence.bool(
                forKey: "usageMemorySourceAgentSessionsEnabled"
            )
        }
        // Repair granted-implies-shown for BOTH consent pairs before anything
        // reads them (see `normalizeConsentShownInvariants`).
        normalizeConsentShownInvariants()
        // Honor the active cached fleet values before any usage lane can open.
        // With no seed the lanes stay CLOSED until `applyUsageRemoteConfig`.
        if let seed = usageRemoteConfigSeed() {
            applyUsageRemoteConfig(
                extractionEnabled: seed.extractionEnabled,
                authorityWritesEnabled: seed.authorityWritesEnabled
            )
        }
        propagateExtractionGate()
        propagateUsageGates()
        propagateCloudModelsGate()
    }

    /// Restore the "granting consent implies the prompt was shown" invariant that
    /// both consent pairs document: a torn persisted state (`granted == true` with
    /// `shown` false or missing — a crash between the coordinator's separate
    /// debounced writes, or a downgrade that wrote only one key) must not
    /// re-prompt a member who already consented.
    ///
    /// WHY THIS EXISTS (U1 review, thread `PRRT_kwDORtgQYs6ZgTEL`): the review read
    /// this as a live defect, on the standard Swift rule that property observers do
    /// not run for assignments made from inside an initializer — which would mean
    /// loading a persisted `granted == true` never executes the `didSet` that sets
    /// `shown`. That rule is real for a plain class, but it does NOT hold here:
    /// `@Observable` rewrites each stored property into a computed property backed
    /// by `_property`, so an `init`-body assignment to a property that already has
    /// a default value goes through the SETTER, and the observer does run. The
    /// invariant therefore already held (verified by isolated probe: the same
    /// class with and without `@Observable` gives opposite results).
    ///
    /// It held **by accident of macro expansion**, though — silently dropping the
    /// `@Observable` annotation, or a change in how the macro treats observers,
    /// would break a consent invariant with no test to catch it. This method makes
    /// the guarantee explicit and independent of that expansion; the repair still
    /// persists because in a method (unlike a plain `init`) observers always run.
    /// Pinned by `UsageMemoryGateTests.testTornConsentStateIsRepairedOnLoad`.
    private func normalizeConsentShownInvariants() {
        if consentGranted, !consentShown { consentShown = true }
        if usageMemoryConsentGranted, !usageMemoryConsentShown { usageMemoryConsentShown = true }
        if cloudModelsEnabled, !cloudModelsConsentShown { cloudModelsConsentShown = true }
    }

    /// Tell the daemon hand-off that the cloud-models policy (or its gate) moved.
    /// Posting is cheap and idempotent; the observer debounces and diffs.
    private func propagateCloudModelsGate() {
        NotificationCenter.default.post(
            name: .memoryCloudModelsPolicyDidChange,
            object: self,
            userInfo: ["enabled": cloudModelsGateEnabled]
        )
    }

    private func propagateExtractionGate() {
        MemoryExtractionKillSwitchRegistry.setAll(
            MemoryExtractionGate.isEnabled(
                consentGranted: consentGranted,
                automaticExtraction: automaticExtraction,
                remoteConfigEnabled: remoteConfigExtractionEnabled
            )
        )
    }

    private func propagateUsageGates() {
        UsageMemoryKillSwitchRegistry.setExtraction(
            UsageMemoryExtractionGate.isEnabled(
                usageConsentGranted: usageMemoryConsentGranted,
                remoteConfigEnabled: remoteConfigUsageExtractionEnabled,
                remoteConfigResolved: hasResolvedUsageRemoteConfig
            )
        )
        UsageMemoryKillSwitchRegistry.setAuthorityWrites(
            UsageMemoryAuthorityWriteGate.isEnabled(
                remoteConfigEnabled: remoteConfigUsageAuthorityWritesEnabled,
                remoteConfigResolved: hasResolvedUsageRemoteConfig
            )
        )
    }
}

// MARK: - Memory extraction gate (G4 kill switch)

/// Pure gate: extraction is enabled only when the user has CONSENTED **and** the
/// user toggle is ON **and** the fleet Remote Config kill switch has not disabled
/// it. Any lever off -> extraction halted (fail-closed). Kept pure so the gate
/// logic is testable without Firebase or a SettingsManager. Consent (G0) is the
/// outermost lever: with it false (the default) the whole loop is dormant.
enum MemoryExtractionGate {
    static func isEnabled(
        consentGranted: Bool,
        automaticExtraction: Bool,
        remoteConfigEnabled: Bool
    ) -> Bool {
        consentGranted && automaticExtraction && remoteConfigEnabled
    }
}

// MARK: - Memory Pro cloud-models gate

/// Pure gate: cloud models for memory are allowed only when the user has
/// CONSENTED to memory **and** turned cloud models on **and** the fleet
/// `memory_cloud_models_enabled` switch has not disabled them. Any lever off
/// -> the daemon policy is handed off disabled (fail-closed). Both user levers
/// default OFF, so nothing leaves the device out of the box.
enum MemoryCloudModelsGate {
    static func isEnabled(
        consentGranted: Bool,
        cloudModelsEnabled: Bool,
        remoteConfigEnabled: Bool
    ) -> Bool {
        consentGranted && cloudModelsEnabled && remoteConfigEnabled
    }
}

// MARK: - Usage memory model placement

/// Where the usage-memory curation model runs. Only the cloud placements can
/// ever satisfy `UsageMemoryCloudGate`; `.local` (the default) keeps the whole
/// pipeline on-device.
enum UsageMemoryModelPlacement: String, CaseIterable, Sendable {
    /// On-device model. Default: nothing usage-derived leaves the machine.
    case local
    /// A user-configured cloud text model.
    case cloudText
    /// The BurnBar-hosted cloud curation service.
    case burnbarCloud

    /// True for any placement that sends usage-derived material off-device.
    var isCloud: Bool { self != .local }
}

// MARK: - Usage memory Remote Config snapshot

/// The two usage-memory fleet switches as read from Firebase Remote Config's
/// **active** (cached or freshly activated) config. Carried as one value so both
/// lanes resolve together — a half-applied snapshot can never leave one lane on
/// its optimistic default while the other honors the fleet.
struct UsageMemoryRemoteConfigSnapshot: Equatable, Sendable {
    /// `memory_usage_extraction_enabled`.
    var extractionEnabled: Bool
    /// `memory_usage_authority_writes_enabled`.
    var authorityWritesEnabled: Bool
}

// MARK: - Usage memory gates (pure)

/// Pure gate: usage-memory extraction is enabled only when the user has
/// CONSENTED **and** the fleet Remote Config kill switch has not disabled it
/// **and** that fleet value has actually been resolved. Any lever off ->
/// extraction halted (fail-closed). Consent defaults OFF and resolution starts
/// false, so the usage loop is dormant out of the box AND during the startup
/// window before Remote Config is read. Kept pure so the gate logic is testable
/// without Firebase or a SettingsManager.
///
/// `remoteConfigResolved` is what keeps a **cached** fleet kill authoritative:
/// the RC field defaults to the optimistic `true`, so without this lever a
/// consenting user's lane would open at init and stay open until the async fetch
/// landed, ignoring a `false` already cached on disk.
enum UsageMemoryExtractionGate {
    static func isEnabled(
        usageConsentGranted: Bool,
        remoteConfigEnabled: Bool,
        remoteConfigResolved: Bool
    ) -> Bool {
        usageConsentGranted && remoteConfigEnabled && remoteConfigResolved
    }
}

/// Pure gate: durable authority writes from the usage pipeline require the
/// `memory_usage_authority_writes_enabled` fleet switch to allow **and** that
/// value to have been resolved. Independent of consent and of the extraction
/// gate by design — the fleet can quarantine usage WRITES without touching
/// read-side behavior — but subject to the same "closed until resolved" rule, so
/// the write lane cannot ride its optimistic default through startup either.
enum UsageMemoryAuthorityWriteGate {
    static func isEnabled(
        remoteConfigEnabled: Bool,
        remoteConfigResolved: Bool
    ) -> Bool {
        remoteConfigEnabled && remoteConfigResolved
    }
}

/// Pure gate: cloud curation of usage memory requires the extraction gate to be
/// open **and** the separate cloud-curation consent **and** a cloud model
/// placement. Any lever off -> zero cloud egress (fail-closed). Both consents
/// default OFF and placement defaults `.local`, so this gate is triply dormant
/// out of the box.
enum UsageMemoryCloudGate {
    static func isEnabled(
        extractionEnabled: Bool,
        cloudConsentGranted: Bool,
        placementIsCloud: Bool
    ) -> Bool {
        extractionEnabled && cloudConsentGranted && placementIsCloud
    }
}

// MARK: - Memory settings service (reset / two-phase forget)

/// Owns the "Reset memory" action and any future memory-settings operations
/// that need a `MemoryServing`. Keeps Firebase/`MemoryServing` dependencies
/// out of the settings store itself.
@MainActor
final class MemorySettingsService {
    enum ResetError: LocalizedError {
        case incomplete(MemoryEventStatus)

        var errorDescription: String? {
            switch self {
            case .incomplete(let status):
                "Memory reset did not complete; backend event status is \(status.rawValue)."
            }
        }
    }

    /// Routes "Reset memory" through backend `deleteAll(scope:)`. Two-phase
    /// forget (soft-delete then hard-delete) is a backend outbox concern; the
    /// frontend simply requests deletion. Canonical chat data is untouched —
    /// memory lives in a separate store. Returns the backend event id, or nil
    /// when no service is wired (production today, until backend PR-5).
    func resetAllMemories(
        memoryService: (any MemoryServing)?,
        scope: MemoryScope
    ) async throws -> MemoryEventID? {
        guard let memoryService else { return nil }
        let eventID = try await memoryService.deleteAll(scope: scope)
        let terminalStatus = try await awaitTerminalStatus(eventID, memoryService: memoryService)
        switch terminalStatus {
        case .succeeded, .merged, .superseded:
            return eventID
        case .pending, .running, .failed, .skipped:
            throw ResetError.incomplete(terminalStatus)
        }
    }

    static func resetScope(userID: String?) -> MemoryScope {
        let normalizedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MemoryScope(
            userID: normalizedUserID?.isEmpty == false ? normalizedUserID : nil,
            appID: "openburnbar"
        )
    }

    private func awaitTerminalStatus(
        _ eventID: MemoryEventID,
        memoryService: any MemoryServing
    ) async throws -> MemoryEventStatus {
        var status = try await memoryService.eventStatus(eventID)
        for _ in 0..<5 where status == .pending || status == .running {
            try await Task.sleep(nanoseconds: 100_000_000)
            status = try await memoryService.eventStatus(eventID)
        }
        return status
    }
}
