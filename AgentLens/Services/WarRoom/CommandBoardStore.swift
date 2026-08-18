import Foundation
import Observation
@preconcurrency import GRDB
import OpenBurnBarKernel

/// Face C's data source: every run across every machine, folded out of
/// `token_usage` (§ The three faces of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// The board wants one row per *run*, not per usage event, so this is a single
/// `GROUP BY sessionId` projection rather than a fetch of `TokenUsage` values.
/// That lets the board read the v62 attribution columns (`originatorKind` /
/// `originatorRef`) that the `TokenUsage` value type does not carry, and keeps
/// the window scan on `token_usage_start_time_idx` (migration v64) instead of
/// walking the whole table.
@MainActor
@Observable
final class CommandBoardStore {
    private(set) var summary = CommandBoard.summarize(runs: [])
    private(set) var hasLoaded = false

    /// A run is "running" while usage kept arriving up to this recently. There
    /// is no end-of-run marker in `token_usage`, so the board infers liveness
    /// from recency and says so rather than claiming a status it cannot know.
    nonisolated static let livenessWindow: TimeInterval = 120

    private let dbQueue: any DatabaseWriter
    private let localMachineName: String

    init(
        dbQueue: any DatabaseWriter,
        localMachineName: String = ProcessInfo.processInfo.hostName
    ) {
        self.dbQueue = dbQueue
        self.localMachineName = localMachineName
    }

    func load(since: Date = Date().addingTimeInterval(-86_400), limit: Int = 200) async {
        let name = localMachineName
        let now = Date()
        do {
            let runs = try await dbQueue.read { db -> [CommandBoardRun] in
                try Row
                    .fetchAll(db, sql: Self.sql, arguments: [since, limit])
                    .compactMap { Self.run(from: $0, localMachineName: name, now: now) }
            }
            // The board reloads on a 10s cadence. Republishing an identical
            // summary would repaint the whole grid for nothing, so an unchanged
            // read stays invisible to observers.
            let next = CommandBoard.summarize(runs: runs)
            if next != summary { summary = next }
        } catch {
            AppLogger.dataStore.silentFailure("command_board_load_failed", error: error)
        }
        if !hasLoaded { hasLoaded = true }
    }

    // MARK: - Projection

    nonisolated private static let sql = """
        SELECT
          sessionId,
          MAX(sourceDeviceId) AS bodyID,
          MAX(sourceDeviceName) AS bodyName,
          MAX(isRemote) AS isRemote,
          MAX(provider) AS provider,
          MAX(model) AS model,
          MAX(projectName) AS projectName,
          MAX(originatorKind) AS originatorKind,
          MAX(originatorRef) AS originatorRef,
          MIN(startTime) AS startedAt,
          MAX(endTime) AS endedAt,
          SUM(cost) AS cost,
          SUM(totalTokens) AS tokens
        FROM token_usage
        WHERE startTime >= ?
        GROUP BY sessionId
        ORDER BY MAX(endTime) DESC
        LIMIT ?
        """

    nonisolated private static func run(
        from row: Row,
        localMachineName: String,
        now: Date
    ) -> CommandBoardRun? {
        guard let sessionId: String = row["sessionId"], !sessionId.isEmpty else { return nil }
        guard let startedAt: Date = row["startedAt"] else { return nil }

        let endedAt: Date? = row["endedAt"]
        let remoteFlag: Int? = row["isRemote"]
        let isRemote = remoteFlag == 1
        let remoteBodyID: String? = row["bodyID"]
        let remoteBodyName: String? = row["bodyName"]
        let originatorKind: String? = row["originatorKind"]
        let originatorRef: String? = row["originatorRef"]
        let cost: Double? = row["cost"]
        let tokens: Int? = row["tokens"]

        let lastActivity = endedAt ?? startedAt
        let isRunning = now.timeIntervalSince(lastActivity) <= livenessWindow

        let fallbackOriginator: BurnBarOriginator = isRemote
            ? .externalInferred
            : BurnBarOriginator(kind: .userLocal, confidence: .inferred)

        return CommandBoardRun(
            id: sessionId,
            // A local row carries no device id; the board groups those under the
            // one machine it is certain about rather than inventing an id.
            bodyID: isRemote ? remoteBodyID : nil,
            bodyDisplayName: isRemote ? (remoteBodyName ?? "Another Mac") : localMachineName,
            title: title(row: row),
            originator: BurnBarOriginator(flatKind: originatorKind, flatRef: originatorRef)
                ?? fallbackOriginator,
            // Never `.succeeded`: silence is not evidence of success, and
            // `token_usage` carries no outcome marker to read.
            status: isRunning ? .running : .ended,
            startedAt: startedAt,
            // A run the board still calls running has no end yet, so the grid
            // measures it against the clock instead of freezing at its last row.
            endedAt: isRunning ? nil : endedAt,
            costUSD: cost ?? 0,
            tokens: tokens ?? 0
        )
    }

    nonisolated private static func title(row: Row) -> String {
        let project: String? = row["projectName"]
        if let project, !project.isEmpty { return project }
        let model: String? = row["model"]
        if let model, !model.isEmpty { return model }
        return row["provider"] ?? "Session"
    }
}
