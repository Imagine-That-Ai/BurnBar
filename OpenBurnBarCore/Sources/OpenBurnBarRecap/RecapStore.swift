import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Persisted `MonthlyRecap` decks, with the sealing rules enforced at the
/// storage boundary rather than trusted to callers.
///
/// Sealing is the promise that last August reads the same way in December. It is
/// enforced here so no code path — a background refresh, a manual regenerate, a
/// schema bump — can quietly rewrite history.
public actor RecapStore {

    public struct Snapshot: Codable, Sendable {
        public var schemaVersion: Int
        public var recaps: [String: MonthlyRecap]

        public init(
            schemaVersion: Int = MonthlyRecap.currentSchemaVersion,
            recaps: [String: MonthlyRecap] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.recaps = recaps
        }
    }

    public enum SaveOutcome: Sendable, Equatable {
        case stored
        /// The stored recap is sealed; the incoming one was discarded.
        case rejectedSealed
        /// Stored, and this was the one-time re-author of a voiceless seal.
        case storedAsVoiceUpgrade
    }

    private let fileURL: URL
    private var snapshot: Snapshot
    private let encoder: JSONEncoder

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        encoder = RecapSnapshotFile.makeEncoder()
        snapshot = try RecapSnapshotFile.load(
            Snapshot.self,
            from: fileURL,
            decoder: RecapSnapshotFile.makeDecoder(),
            fallback: { Snapshot() }
        )

        // A deck folded from an older `RecapFacts` shape can no longer be
        // trusted against current comparisons, so it is dropped and rebuilt.
        snapshot.recaps = snapshot.recaps.filter {
            $0.value.factsSchemaVersion == RecapFacts.currentSchemaVersion
                && $0.value.schemaVersion == MonthlyRecap.currentSchemaVersion
        }
    }

    // MARK: - Reads

    public func recap(for window: RecapWindow) -> MonthlyRecap? {
        snapshot.recaps[window.key]
    }

    /// Months with a stored recap, newest first.
    public func availableMonths() -> [RecapWindow] {
        snapshot.recaps.values.map(\.window).sorted(by: >)
    }

    // MARK: - Writes

    @discardableResult
    public func save(_ recap: MonthlyRecap) throws -> SaveOutcome {
        let existing = snapshot.recaps[recap.window.key]

        if let existing, existing.sealState.isSealed {
            // The only mutation a sealed month accepts: adding the writing it
            // never got. Anything else — including a second voice pass — is
            // refused, so the deck a person read in September is the deck they
            // find in December.
            guard existing.sealState == .sealedWithoutVoice, recap.isVoiceAuthored else {
                return .rejectedSealed
            }
            snapshot.recaps[recap.window.key] = recap.sealed(as: .sealed)
            try persist()
            return .storedAsVoiceUpgrade
        }

        snapshot.recaps[recap.window.key] = recap
        try persist()
        return .stored
    }

    private func persist() throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
