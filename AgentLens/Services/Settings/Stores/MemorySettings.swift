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
        didSet { persistence.set(automaticExtraction, forKey: "memoryAutomaticExtraction") }
    }

    /// Opt-in sub-toggle: high-recall per-reply (default OFF).
    var highRecallPerReply: Bool = false {
        didSet { persistence.set(highRecallPerReply, forKey: "memoryHighRecallPerReply") }
    }

    /// Firebase Remote Config `memory_extraction_enabled` (default true). Not
    /// user-settable; the fleet kill switch sets this false to halt extraction
    /// instantly. Fail-closed: a fetch error flips this false.
    var remoteConfigExtractionEnabled: Bool = true

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        if persistence.objectExists(forKey: "memoryAutomaticExtraction") {
            self.automaticExtraction = persistence.bool(forKey: "memoryAutomaticExtraction")
        }
        if persistence.objectExists(forKey: "memoryHighRecallPerReply") {
            self.highRecallPerReply = persistence.bool(forKey: "memoryHighRecallPerReply")
        }
    }
}

// MARK: - Memory extraction gate (G4 kill switch)

/// Pure gate: extraction is enabled only when the user toggle is ON **and** the
/// fleet Remote Config kill switch has not disabled it. Either lever off ->
/// extraction halted (fail-closed). Kept pure so the gate logic is testable
/// without Firebase or a SettingsManager.
enum MemoryExtractionGate {
    static func isEnabled(automaticExtraction: Bool, remoteConfigEnabled: Bool) -> Bool {
        automaticExtraction && remoteConfigEnabled
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
