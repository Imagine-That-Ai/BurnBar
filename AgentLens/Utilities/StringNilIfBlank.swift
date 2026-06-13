import Foundation

// Shared trim-or-nil helper for the AgentLens (macOS) target. Consolidates
// the previously duplicated `private` copy that lived in
// CLIAgentSessionMirror.swift.

internal extension String {
    /// Returns the whitespace/newline-trimmed string, or `nil` when the
    /// trimmed result is empty.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
