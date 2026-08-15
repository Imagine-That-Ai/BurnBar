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
        }
    }

    /// Whether the first-run memory consent prompt has been presented (so it is not
    /// shown again). Set when consent is granted, or when the user declines.
    var consentShown: Bool = false {
        didSet { persistence.set(consentShown, forKey: "memoryConsentShown") }
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
    var remoteConfigUsageExtractionEnabled: Bool = true {
        didSet { propagateUsageGates() }
    }

    /// Firebase Remote Config `memory_usage_authority_writes_enabled` (default
    /// true). Not user-settable and not persisted; a fleet flip to false halts
    /// durable authority writes from the usage pipeline while leaving extraction
    /// gating untouched.
    var remoteConfigUsageAuthorityWritesEnabled: Bool = true {
        didSet { propagateUsageGates() }
    }

    init(persistence: SettingsPersistenceCoordinator) {
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
        propagateExtractionGate()
        propagateUsageGates()
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
                remoteConfigEnabled: remoteConfigUsageExtractionEnabled
            )
        )
        UsageMemoryKillSwitchRegistry.setAuthorityWrites(remoteConfigUsageAuthorityWritesEnabled)
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

// MARK: - Usage memory gates (pure)

/// Pure gate: usage-memory extraction is enabled only when the user has
/// CONSENTED **and** the fleet Remote Config kill switch has not disabled it.
/// Either lever off -> extraction halted (fail-closed). Consent defaults OFF,
/// so the usage loop is dormant out of the box. Kept pure so the gate logic is
/// testable without Firebase or a SettingsManager.
enum UsageMemoryExtractionGate {
    static func isEnabled(
        usageConsentGranted: Bool,
        remoteConfigEnabled: Bool
    ) -> Bool {
        usageConsentGranted && remoteConfigEnabled
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
