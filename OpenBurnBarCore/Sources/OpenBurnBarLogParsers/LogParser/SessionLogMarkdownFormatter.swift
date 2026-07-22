import Foundation

// MARK: - Session Log Markdown Formatter (parser-safe, Foundation-only)
//
// Windows-port Phase-2 (G2 parser lift, `docs/WINDOWS_PORT_MASTER_PLAN.md`).
//
// Only the parser-safe renderer lives in `OpenBurnBarCore`: `transcriptTurnMarkdown`
// feeds `ConversationRecord.fullText` inside the lifted parsers (Claude / Hermes),
// so it must be Foundation-only and Windows-buildable.
//
// The app-facing renderers (`markdown(for:)`, `cliMarkdown(from:)`,
// `providerMarkdown(_:)`) depend on macOS-app chat types (`ChatMessageRecord`,
// `ChatTranscriptPiece`) and UI accessors, so they live in the app-side extension
// `AgentLens/Services/SessionLogMarkdownFormatter+App.swift`. Keeping them out of
// the Engine keeps this type Foundation-only; declaring them here as well would
// (a) fail to compile off-Apple (`ChatMessageRecord` is app-only) and (b) collide
// with the app extension's declarations on Apple.
public enum SessionLogMarkdownFormatter {

    /// One message turn in stored provider `fullText` — matches `cliMarkdown` headings so
    /// `TranscriptBlockParser` can label You vs Assistant in Session Logs.
    public static func transcriptTurnMarkdown(isAssistant: Bool, body: String) -> String {
        let header = isAssistant ? "## Assistant" : "## You"
        return "\(header)\n\n\(body)"
    }
}
