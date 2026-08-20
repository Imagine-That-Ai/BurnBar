import Foundation

// Shared trim-or-nil helpers for the mobile target. Consolidates the
// previously duplicated `private`/`fileprivate` copies that lived in
// HermesChatMessage.swift, HermesService.swift, QuotaStore.swift,
// HermesTabView.swift, PiService.swift, and HermesCloudLibraryStore.swift
// (see the old TODO(tech-debt) note in HermesChatMessage.swift).

internal extension String {
    /// Returns the whitespace/newline-trimmed string, or `nil` when the
    /// trimmed result is empty.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns `nil` when the string is *exactly* empty, otherwise the string
    /// unchanged. Whitespace is significant and preserved.
    ///
    /// Distinct from `nilIfBlank`, which trims: use this only where the value
    /// was already normalised upstream and the raw bytes must survive.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    /// Returns `nil` when the string is empty or only whitespace, otherwise the
    /// string **unchanged**, including its surrounding whitespace.
    ///
    /// The blankness test matches `nilIfBlank`; the return value deliberately
    /// does not. Some call sites decide on blankness but must forward the
    /// original bytes, and collapsing the two would silently begin trimming
    /// values that are round-tripped elsewhere.
    var nilIfBlankPreservingWhitespace: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

internal extension Optional where Wrapped == String {
    /// Returns the whitespace/newline-trimmed wrapped string, or `nil` when
    /// the value is absent or trims to empty.
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
