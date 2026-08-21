import Foundation
@testable import OpenBurnBarCore
@testable import OpenBurnBarRecap

/// Deterministic fixtures for the recap engine.
///
/// Everything is built against a fixed Gregorian calendar in a fixed time zone.
/// The fold buckets by local day and hour, so a floating calendar would make
/// these tests pass or fail depending on where they run.
enum RecapFixtures {

    static func calendar(_ identifier: String = "America/Los_Angeles") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // A fixed zone, not the machine's: the fold buckets by local day and
        // hour, so a floating zone would make these tests pass or fail by
        // geography. Falling back to UTC keeps the fixture total.
        calendar.timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0) ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0,
        calendar: Calendar = RecapFixtures.calendar()
    ) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    static func usage(
        session: String,
        provider: String = "Claude Code",
        model: String = "Claude Opus 5",
        project: String? = "BurnBar",
        start: Date,
        durationMinutes: Double = 20,
        cost: Double = 1.0,
        input: Int = 1_000,
        output: Int = 500,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheCreation: Int = 0
    ) -> InsightUsageRow {
        InsightUsageRow(
            sessionID: session,
            provider: provider,
            model: model,
            projectName: project,
            startTime: start,
            endTime: start.addingTimeInterval(durationMinutes * 60),
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            totalTokens: input + output + reasoning + cacheRead + cacheCreation,
            costUSD: cost
        )
    }

    static func session(
        id: String,
        provider: String = "Claude Code",
        project: String? = "BurnBar",
        start: Date,
        messages: Int = 12,
        tools: [String] = ["Read", "Edit", "Bash"]
    ) -> InsightSessionRow {
        InsightSessionRow(
            sessionID: id,
            provider: provider,
            projectName: project,
            startTime: start,
            endTime: start.addingTimeInterval(1_200),
            messageCount: messages,
            inferredTaskTitle: nil,
            keyTools: tools,
            keyCommands: [],
            keyFiles: []
        )
    }

    /// A busy, believable month: daily work, a Tuesday bias, a late-night
    /// stretch, two models and two projects.
    static func busyMonth(
        _ window: RecapWindow,
        calendar: Calendar = RecapFixtures.calendar(),
        costScale: Double = 1.0
    ) -> RecapRowBatch {
        var usages: [InsightUsageRow] = []
        var sessions: [InsightSessionRow] = []
        let dayCount = window.dayCount(calendar: calendar)

        for day in 1...dayCount {
            let base = date(window.year, window.month, day, 10, calendar: calendar)
            let weekday = calendar.component(.weekday, from: base)
            // Sunday (1) is quiet.
            guard weekday != 1 else { continue }
            // Tuesday (3) gets extra sessions — the weekday-personality signal.
            let sessionsToday = weekday == 3 ? 4 : 2

            for index in 0..<sessionsToday {
                let id = "s-\(window.key)-\(day)-\(index)"
                let hour = index == 0 ? 10 : (index == 1 ? 15 : 1)
                let start = date(window.year, window.month, day, hour, calendar: calendar)
                let usesOpus = (day + index).isMultiple(of: 3)
                usages.append(usage(
                    session: id,
                    provider: usesOpus ? "Claude Code" : "Codex",
                    model: usesOpus ? "Claude Opus 5" : "GPT-5",
                    project: index.isMultiple(of: 2) ? "BurnBar" : "Website",
                    start: start,
                    durationMinutes: 25,
                    cost: 1.2 * costScale,
                    input: 4_000,
                    output: 1_500,
                    reasoning: 400,
                    cacheRead: 6_000,
                    cacheCreation: 900
                ))
                sessions.append(session(
                    id: id,
                    provider: usesOpus ? "Claude Code" : "Codex",
                    project: index.isMultiple(of: 2) ? "BurnBar" : "Website",
                    start: start
                ))
            }
        }

        return RecapRowBatch(
            window: window,
            usages: usages,
            sessions: sessions,
            isPartial: false,
            hasSessionData: true,
            exactShare: 1.0
        )
    }

    /// Barely-there month: below the substance floor.
    static func thinMonth(
        _ window: RecapWindow,
        calendar: Calendar = RecapFixtures.calendar()
    ) -> RecapRowBatch {
        let usages = (1...3).map { day in
            usage(
                session: "thin-\(day)",
                start: date(window.year, window.month, day, 9, calendar: calendar),
                cost: 0.2
            )
        }
        return RecapRowBatch(
            window: window,
            usages: usages,
            sessions: [],
            isPartial: false,
            hasSessionData: false,
            exactShare: 1.0
        )
    }

    static func facts(
        _ window: RecapWindow,
        calendar: Calendar = RecapFixtures.calendar(),
        costScale: Double = 1.0
    ) -> RecapFacts {
        RecapFacts.build(
            batch: busyMonth(window, calendar: calendar, costScale: costScale),
            builtAt: window.end(calendar: calendar),
            calendar: calendar
        )
    }

    static func context(
        _ window: RecapWindow,
        historyMonths: Int = 3,
        calendar: Calendar = RecapFixtures.calendar()
    ) -> RecapContext {
        let history = window.priorMonths(historyMonths).map {
            facts($0, calendar: calendar, costScale: 0.7)
        }
        return RecapContext(
            facts: facts(window, calendar: calendar),
            history: history,
            calendar: calendar
        )
    }

    static func temporaryFileURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }
}
