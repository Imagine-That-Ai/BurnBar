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
