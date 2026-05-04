import Foundation
import SwiftUI
@testable import OpenBurnBar

// MARK: - Token Usage Fixtures

enum ViewTestFixtures {

    // MARK: - Token Usage

    static func makeUsage(
        provider: AgentProvider = .factory,
        sessionId: String = "session-1",
        projectName: String = "TestProject",
        model: String = "claude-3-opus",
        inputTokens: Int = 100,
        outputTokens: Int = 50,
        costUSD: Double = 0.05,
        startTime: Date = Date(),
        endTime: Date = Date().addingTimeInterval(60)
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            startTime: startTime,
            endTime: endTime
        )
    }

    static func makeWeekOfUsages(
        provider: AgentProvider = .factory,
        baseCost: Double = 1.0
    ) -> [TokenUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (1...7).map { d in
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            return makeUsage(
                provider: provider,
                sessionId: "s\(d)",
                costUSD: baseCost * Double(d),
                startTime: day.addingTimeInterval(3600),
                endTime: day.addingTimeInterval(7200)
            )
        }
    }

    // MARK: - Chat Messages

    static func makeUserMessage(
        id: String = "msg-user-1",
        content: String = "Hello, can you help me?"
    ) -> ChatMessageRecord {
        ChatMessageRecord(
            id: id,
            role: .user,
            content: content
        )
    }

    static func makeAssistantMessage(
        id: String = "msg-asst-1",
        content: String = "Sure, I can help with that.",
        cliUsed: String? = nil,
        transcriptPieces: [ChatTranscriptPiece] = []
    ) -> ChatMessageRecord {
        ChatMessageRecord(
            id: id,
            role: .assistant,
            content: content,
            cliUsed: cliUsed,
            transcriptPieces: transcriptPieces
        )
    }

    static func makeTranscriptMessage(
        id: String = "msg-transcript-1",
        pieces: [ChatTranscriptPiece],
        cliUsed: String? = nil
    ) -> ChatMessageRecord {
        ChatMessageRecord(
            id: id,
            role: .assistant,
            content: "",
            cliUsed: cliUsed,
            transcriptPieces: pieces
        )
    }

    static func makeTextPiece(
        id: String = "piece-1",
        value: String = "Some text"
    ) -> ChatTranscriptPiece {
        ChatTranscriptPiece(id: id, kind: .text, value: value)
    }

    static func makeToolUsePiece(
        id: String = "tool-1",
        name: String = "Read",
        detail: String = "Read file /path/to/file.swift"
    ) -> ChatTranscriptPiece {
        ChatTranscriptPiece(id: id, kind: .toolUse, value: name, detail: detail)
    }

    // MARK: - Hermes Message Fixtures

    static func makeHermesAssistantMessage(
        id: String = "msg-hermes-1",
        textPieces: [String],
        toolPieces: [(name: String, detail: String)] = [],
        cliUsed: String = "hermes"
    ) -> ChatMessageRecord {
        var pieces: [ChatTranscriptPiece] = []
        for (i, text) in textPieces.enumerated() {
            pieces.append(.init(id: "\(id)-text-\(i)", kind: .text, value: text))
        }
        for (i, tool) in toolPieces.enumerated() {
            pieces.append(.init(id: "\(id)-tool-\(i)", kind: .toolUse, value: tool.name, detail: tool.detail))
        }
        return makeTranscriptMessage(id: id, pieces: pieces, cliUsed: cliUsed)
    }

    // MARK: - Insight Brief

    static func makeInsightBrief(
        whereLeftOff: String? = "Working on auth module",
        whereLeftOffProject: String? = "OpenBurnBar",
        heaviestTaskTitle: String? = "Auth refactor",
        heaviestTaskCost: Double? = 2.50,
        heaviestTaskProject: String? = "OpenBurnBar",
        modelShiftHeadline: String? = nil,
        incompleteHint: String? = nil,
        rollupFreshness: InsightRollupFreshness = .fresh,
        rollupStatusMessage: String? = nil
    ) -> InsightBriefSnapshot {
        InsightBriefSnapshot(
            whereLeftOff: whereLeftOff,
            whereLeftOffProject: whereLeftOffProject,
            heaviestTaskTitle: heaviestTaskTitle,
            heaviestTaskCost: heaviestTaskCost,
            heaviestTaskProject: heaviestTaskProject,
            modelShiftHeadline: modelShiftHeadline,
            incompleteHint: incompleteHint,
            rollupFreshness: rollupFreshness,
            rollupStatusMessage: rollupStatusMessage
        )
    }
}
