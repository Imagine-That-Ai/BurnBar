import Foundation

public extension String {
    /// Returns the whitespace/newline-trimmed string, or `nil` when the trimmed result is empty.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension Optional where Wrapped == String {
    /// Returns the whitespace/newline-trimmed wrapped string, or `nil` when absent or blank.
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
