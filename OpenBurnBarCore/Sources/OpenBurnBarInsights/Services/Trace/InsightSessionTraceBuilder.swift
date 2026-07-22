import Foundation

/// Assembles a `VerdictTraceStrip` from operating action history.
///
/// Plan §4.6 — the trace strip is the highest-leverage new visual.
/// It turns the verdict from a stat sheet into an X-ray of the day.
/// This builder joins session metadata with cost ticks to produce the
/// strip that the `VerdictHeroView` renders.
public struct InsightSessionTraceBuilder: Sendable {

    public init() {}

    /// Build a trace strip for the most consequential session in the
    /// snapshot. "Consequential" is defined as highest cost, with
    /// fallback to longest duration and then most recent.
    public func build(
        from snapshot: InsightDataSnapshot
    ) -> VerdictTraceStrip? {
        guard let session = pickConsequentialSession(from: snapshot) else {
            return nil
        }

        let lanes = buildLanes(for: session, actions: snapshot.operatingActions)
        let ticks = buildTicks(for: session, usages: snapshot.usages)

        return VerdictTraceStrip(
            sessionID: session.sessionID,
            lanes: lanes,
            ticks: ticks,
            startedAt: session.startTime,
            endedAt: session.endTime,
            summary: session.inferredTaskTitle
                ?? "Session \(session.sessionID.prefix(8))",
            costUSD: sessionCost(session, usages: snapshot.usages),
            didTimeout: session.endTime.timeIntervalSince(session.startTime) > 300,
            tint: ProviderTint.forProviderKey(session.provider)
        )
    }

    // MARK: - Session selection

    private func pickConsequentialSession(from snapshot: InsightDataSnapshot) -> InsightSessionRow? {
        let scored = snapshot.sessions.map { session -> (session: InsightSessionRow, score: Double) in
            let cost = sessionCost(session, usages: snapshot.usages)
            let duration = session.endTime.timeIntervalSince(session.startTime)
            let recency = -session.startTime.timeIntervalSinceNow
            // Weight: cost 50%, duration 30%, recency 20%
            let score = cost * 0.5 + (duration / 60.0) * 0.3 + (recency / 3600.0) * 0.2
            return (session, score)
        }
        return scored.max(by: { $0.score < $1.score })?.session
    }

    private func sessionCost(_ session: InsightSessionRow, usages: [InsightUsageRow]) -> Double {
        usages
            .filter { $0.sessionID == session.sessionID && $0.provider == session.provider }
            .reduce(0) { $0 + $1.costUSD }
    }

    // MARK: - Lane construction

    private func buildLanes(
        for session: InsightSessionRow,
        actions: [InsightOperatingAction]
    ) -> [TraceLane] {
        var lanes: [TraceLane] = []
        let sessionActions = actions
            .filter { $0.sessionID == session.sessionID }
            .sorted { $0.occurredAt < $1.occurredAt }

        // Prompt lane (first 2 seconds)
        lanes.append(TraceLane(
            kind: .prompt,
            label: "Prompt",
            startOffset: 0,
            duration: 2.0,
            tint: ProviderTint.forProviderKey(session.provider)
        ))

        var currentOffset: TimeInterval = 2.0

        for action in sessionActions {
            let duration = max(0.5, min(3.0, action.duration ?? 1.0))
            let kind: TraceLane.Kind
            switch action.actionKind {
            case "tool_call", "tool_use": kind = .tool
            case "cache_hit", "cache_read": kind = .cache
            case "retry", "retry_attempt": kind = .retry
            case "model_call", "completion": kind = .model
            default: kind = .tool
            }

            lanes.append(TraceLane(
                kind: kind,
                label: String(action.summary.prefix(20)),
                startOffset: currentOffset,
                duration: duration,
                tint: ProviderTint.forProviderKey(session.provider)
            ))
            currentOffset += duration
        }

        // Response lane (final 3 seconds or remaining duration)
        let totalDuration = session.endTime.timeIntervalSince(session.startTime)
        let responseDuration = max(1.0, totalDuration - currentOffset)
        lanes.append(TraceLane(
            kind: .response,
            label: "Response",
            startOffset: currentOffset,
            duration: responseDuration,
            tint: ProviderTint.forProviderKey(session.provider)
        ))

        return lanes
    }

    // MARK: - Tick construction

    private func buildTicks(
        for session: InsightSessionRow,
        usages: [InsightUsageRow]
    ) -> [TraceTick] {
        let sessionUsages = usages
            .filter { $0.sessionID == session.sessionID && $0.provider == session.provider }
            .sorted { $0.startTime < $1.startTime }

        var ticks: [TraceTick] = []
        var accumulatedCost: Double = 0

        for usage in sessionUsages {
            accumulatedCost += usage.costUSD
            let offset = usage.startTime.timeIntervalSince(session.startTime)
            ticks.append(TraceTick(
                offset: max(0, offset),
                costUSD: accumulatedCost,
                label: offset > 0 ? nil : "start"
            ))
        }

        // Cap to avoid bloat
        if ticks.count > 12 {
            let strideCount = ticks.count / 12
            ticks = Array(ticks.enumerated().compactMap { idx, tick in
                idx % strideCount == 0 ? tick : nil
            }.prefix(12))
        }

        return ticks
    }
}
