import Foundation
import Observation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Memory sync status row (E19, app half)
//
// What this surface reports, and what it refuses to report.
//
// Memory sync has TWO transport cursors and ONE consent marker, and any of the
// three can stall on its own:
//
//   * `remote_sync_watermarks` / `memory_facts` — the fact cursor.
//   * `remote_sync_watermarks` / `memory_forget_receipts` — the retirement
//     cursor. Its own row on purpose: receipts are ordered by `replicatedAt`
//     and facts by `updatedAt`, so a shared cursor would let either channel
//     skip the other's documents. Reporting one of the two would therefore hide
//     the case this row exists to catch — retirements stalled while facts flow.
//   * `BurnBarMemoryDeviceSyncMarker` — the app's live claim that a consenting
//     gate is standing behind the daemon's drains.
//
// **This row raises no alerts, on purpose.** E19 asks for the app debug row to
// be *health-card input*, and the Memory health card ships directly above it in
// the same section. The card already owns `SYNC_MARKER_STALE` at the daemon's
// own bound, so a second emitter here would render the same code twice in one
// scroll and split one doctrine across two implementations. What this row adds
// is the ledgers the card does not show — the second cursor, and the inbox
// counts — reported as ages and counts a human reads next to the card's
// findings. Every formatter, threshold and query it needs is the card's own
// (`MemoryHealthLocalFindings.age`, `ProjectMemoryHealthCardModel.StatRow`,
// `ControlPlaneStore.memoryDeviceSyncMarkerReading`), so there is exactly one
// implementation of each.
//
// Everything here is read from state the app already keeps. No new table, no
// new counter, no new RPC. A value this Mac did not observe renders `—`, never
// `0`, and the two counters the app genuinely does not hold say so out loud
// rather than rendering a zero that would read as "nothing was rejected".

/// The sync-status row's rendered state, built from a
/// `MemorySyncObservabilitySnapshot` and an instant.
///
/// Exposed as data so every rendered value — including the placeholders — is
/// assertable without a snapshot test.
struct MemorySyncStatusModel: Equatable, Sendable {

    // MARK: Notes

    /// Why a non-zero `skipped` is expected once the engine half of this surface
    /// lands, so an operator does not read the floor as a fault.
    static let permanentSkippedFloorNote =
        "A permanent non-zero \"skipped\" is expected, not a fault: chat memories in "
        + "users/{uid}/memory_facts written before project scoping carry no engine projectID, "
        + "so every pull skips all of them."

    /// The labelled statement that keeps the two absent counters honest. Without
    /// it, "Rejected —" reads as a rendering bug rather than as a boundary.
    static let counterProvenanceNote =
        "Rejected and skipped counts are not measured here. This Mac persists the inbox, not the "
        + "per-cycle pull tally, so those two come from the memory engine's own metrics."

    /// What a dash on the consent marker means, and where its staleness is
    /// reported. Both halves matter: the dash covers the two states the daemon
    /// reads as no consent, and the pointer keeps this row from looking like it
    /// is silently passing a marker the card is warning about.
    static let markerReadingNote =
        "Consent marker: \"\(ProjectMemoryHealthCardModel.placeholder)\" is what the daemon reads as "
        + "NO consent — either no marker row on this Mac, or more than one, which is ambiguous and "
        + "fails closed the same way. Whether a present marker has gone stale is reported by the "
        + "Memory health card above, which owns that finding."

    /// What the marker stat shows when the marker names somebody else. The
    /// daemon scopes every drain to the member the marker names, so this Mac
    /// is draining to them, not to you — an age would be true and useless.
    static let markerNamesAnotherMember = "Another member"

    // MARK: State

    /// When the snapshot behind this model was read. The row is a one-shot
    /// read, so the ages below are ages as of THIS instant and are stated as
    /// such rather than ticking on their own.
    let readAt: Date

    let factsWatermarkAge: String
    let receiptsWatermarkAge: String
    let markerAge: String
    let parkedRows: Int?
    let mergedRows: Int?

    /// The stats the row renders, in order.
    var statRows: [ProjectMemoryHealthCardModel.StatRow] {
        [
            ProjectMemoryHealthCardModel.StatRow(title: "Facts cursor", value: factsWatermarkAge),
            ProjectMemoryHealthCardModel.StatRow(title: "Receipts cursor", value: receiptsWatermarkAge),
            ProjectMemoryHealthCardModel.StatRow(title: "Consent marker", value: markerAge),
            ProjectMemoryHealthCardModel.StatRow(
                title: "Parked",
                value: parkedRows.map(String.init) ?? ProjectMemoryHealthCardModel.placeholder
            ),
            ProjectMemoryHealthCardModel.StatRow(
                title: "Merged (30 d)",
                value: mergedRows.map(String.init) ?? ProjectMemoryHealthCardModel.placeholder
            ),
            ProjectMemoryHealthCardModel.StatRow(
                title: "Rejected",
                value: ProjectMemoryHealthCardModel.placeholder
            ),
            ProjectMemoryHealthCardModel.StatRow(
                title: "Skipped",
                value: ProjectMemoryHealthCardModel.placeholder
            )
        ]
    }

    // MARK: Construction

    init(snapshot: MemorySyncObservabilitySnapshot, now: Date = Date()) {
        readAt = now
        factsWatermarkAge = MemoryHealthLocalFindings.age(of: snapshot.memoryFactsWatermarkAt, now: now)
        receiptsWatermarkAge = MemoryHealthLocalFindings.age(of: snapshot.forgetReceiptsWatermarkAt, now: now)
        markerAge = Self.markerStat(snapshot: snapshot, now: now)
        parkedRows = snapshot.parkedInboxRows
        mergedRows = snapshot.mergedInboxRows
    }

    /// The consent-marker stat.
    ///
    /// An absent reading — no row, or the ambiguous two-row table the daemon
    /// refuses to pick a winner from — is the placeholder, because both of
    /// those ARE the no-consent state and rendering "just now" for either would
    /// reassure a member during the exact outage this row exists to explain.
    /// A marker naming somebody else is named as such rather than aged.
    private static func markerStat(snapshot: MemorySyncObservabilitySnapshot, now: Date) -> String {
        let marker = snapshot.deviceSyncMarker
        guard marker.accountUid != nil else { return ProjectMemoryHealthCardModel.placeholder }
        // The one comparison, shared with the health card above
        // (`MemoryDeviceSyncMarkerReading.namesAnotherMember(than:)`), so the
        // two surfaces cannot disagree about whose marker this is.
        if marker.namesAnotherMember(than: snapshot.accountUid) { return markerNamesAnotherMember }
        return MemoryHealthLocalFindings.age(of: marker.refreshedAt, now: now)
    }
}

// MARK: - View

/// The sync-status row itself. Renders only what the model holds.
struct MemorySyncDebugRow: View {
    let model: MemorySyncStatusModel
    let refresh: (() -> Void)?

    init(model: MemorySyncStatusModel, refresh: (() -> Void)? = nil) {
        self.model = model
        self.refresh = refresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                ForEach(model.statRows) { row in
                    statColumn(row)
                }
                Spacer(minLength: 0)
            }

            readAtRow

            note(MemorySyncStatusModel.markerReadingNote)
            note(MemorySyncStatusModel.counterProvenanceNote)
            note(MemorySyncStatusModel.permanentSkippedFloorNote)
        }
    }

    /// The ages above are a snapshot, not a live clock. Saying when they were
    /// read is what keeps "4 min ago" from being a lie ten minutes later.
    private var readAtRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text("Read at \(Self.clock.string(from: model.readAt)) — these ages do not tick.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            if let refresh {
                Button("Refresh", action: refresh)
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.ember)
            }
            Spacer(minLength: 0)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private func statColumn(_ row: ProjectMemoryHealthCardModel.StatRow) -> some View {
        let tint: Color = switch row.emphasis {
        case .neutral: DesignSystem.Colors.textPrimary
        case .good: DesignSystem.Colors.success
        case .bad: DesignSystem.Colors.amber
        }

        return VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(row.value)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
        }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(.top, 1)
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Host model

/// Owns the row's read. Held in `@State` by the host so a Settings redraw
/// cannot replace a loaded row with an empty one.
@MainActor @Observable
final class MemorySyncStatusRowModel {

    typealias LoadSnapshot = () async throws -> MemorySyncObservabilitySnapshot

    private(set) var status: MemorySyncStatusModel?
    private(set) var loadFailure: String?
    private(set) var isLoading = false

    private let loadSnapshot: LoadSnapshot

    init(loadSnapshot: @escaping LoadSnapshot) {
        self.loadSnapshot = loadSnapshot
    }

    func load() async {
        guard isLoading == false else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            status = MemorySyncStatusModel(snapshot: try await loadSnapshot())
            loadFailure = nil
        } catch {
            // "We could not read the store" is not "everything is zero". The
            // row says which one it is.
            status = nil
            loadFailure = error.localizedDescription
        }
    }
}

// MARK: - Host

@MainActor
struct MemorySyncDebugRowHost: View {
    let store: ControlPlaneStore
    let accountUid: String?

    @State private var model: MemorySyncStatusRowModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                loadingRow
            }
        }
        // Keyed on the member: a sign-out or an account switch while Settings
        // is open must not leave the departed member's counts on screen. A
        // changed id rebuilds the model against the new account and reloads.
        .task(id: accountUid) {
            let model = makeModel()
            self.model = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ model: MemorySyncStatusRowModel) -> some View {
        if let status = model.status {
            MemorySyncDebugRow(model: status) {
                Task { await model.load() }
            }
        } else if let failure = model.loadFailure {
            // A read error is the branch that MOST needs a retry: it is usually
            // transient (the daemon holding a write, the store briefly locked),
            // and without a button here the row stays stranded until the member
            // switches account or leaves Settings.
            unavailable(failure) { Task { await model.load() } }
        } else {
            loadingRow
        }
    }

    private var loadingRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text("Reading sync state…")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func unavailable(_ detail: String, refresh: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.amber)
            Text("Sync state could not be read — \(detail)")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Refresh", action: refresh)
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.ember)
            Spacer(minLength: 0)
        }
    }

    private func makeModel() -> MemorySyncStatusRowModel {
        let store = store
        let accountUid = accountUid
        return MemorySyncStatusRowModel(
            loadSnapshot: { try await store.memorySyncObservabilitySnapshot(accountUid: accountUid) }
        )
    }
}
