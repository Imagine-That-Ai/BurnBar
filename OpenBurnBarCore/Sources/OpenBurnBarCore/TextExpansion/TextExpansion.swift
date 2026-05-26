import Foundation

// MARK: - Text Expansion Models

public enum TextExpansionMode: String, Codable, CaseIterable, Sendable, Equatable {
    case staticText = "static"
    case llmRewrite = "llm_rewrite"
}

public enum TextExpansionSurface: String, Codable, CaseIterable, Sendable, Equatable {
    case inAppThread = "in_app_thread"
    case macGlobal = "mac_global"
    case iOSKeyboard = "ios_keyboard"
    case androidIME = "android_ime"
}

public struct TextExpansionScope: Codable, Equatable, Sendable {
    public var surfaces: [TextExpansionSurface]
    public var bundleIdentifiers: [String]
    public var threadIDs: [String]

    public init(
        surfaces: [TextExpansionSurface] = TextExpansionSurface.allCases,
        bundleIdentifiers: [String] = [],
        threadIDs: [String] = []
    ) {
        self.surfaces = surfaces
        self.bundleIdentifiers = bundleIdentifiers
        self.threadIDs = threadIDs
    }

    public static let global = TextExpansionScope()

    public func allows(surface: TextExpansionSurface, bundleIdentifier: String? = nil, threadID: String? = nil) -> Bool {
        guard surfaces.contains(surface) else { return false }
        if !bundleIdentifiers.isEmpty {
            guard let bundleIdentifier,
                  bundleIdentifiers.contains(where: { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }) else {
                return false
            }
        }
        if !threadIDs.isEmpty {
            guard let threadID, threadIDs.contains(threadID) else { return false }
        }
        return true
    }
}

public struct TextExpansionSnippet: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Canonical trigger name without the `&&` prefix.
    public var trigger: String
    public var body: String
    public var mode: TextExpansionMode
    public var isEnabled: Bool
    public var scope: TextExpansionScope
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var syncedAt: Date?
    public var sourceDeviceID: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        trigger: String,
        body: String,
        mode: TextExpansionMode = .staticText,
        isEnabled: Bool = true,
        scope: TextExpansionScope = .global,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        syncedAt: Date? = nil,
        sourceDeviceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.trigger = TextExpansionTrigger.canonicalName(trigger)
        self.body = body
        self.mode = mode
        self.isEnabled = isEnabled
        self.scope = scope
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncedAt = syncedAt
        self.sourceDeviceID = sourceDeviceID
    }

    public var activationToken: String {
        TextExpansionTrigger.prefix + trigger
    }

    public var isActive: Bool {
        isEnabled && deletedAt == nil && !trigger.isEmpty
    }
}

public struct TextExpansionSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var snippets: [TextExpansionSnippet]

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        snippets: [TextExpansionSnippet]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.snippets = snippets
    }
}

// MARK: - Trigger Normalization

public enum TextExpansionTrigger {
    public static let prefix = "&&"
    public static let minLength = 2
    public static let maxLength = 64

    public static func canonicalName(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        return value.lowercased()
    }

    public static func activationToken(for raw: String) -> String {
        prefix + canonicalName(raw)
    }

    public static func validationError(for raw: String) -> String? {
        let name = canonicalName(raw)
        if name.count < minLength {
            return "Trigger must be at least \(minLength) characters."
        }
        if name.count > maxLength {
            return "Trigger must be \(maxLength) characters or shorter."
        }
        for scalar in name.unicodeScalars {
            let value = scalar.value
            let isLowercase = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            let isAllowedSymbol = scalar == "_" || scalar == "-"
            if !(isLowercase || isDigit || isAllowedSymbol) {
                return "Use lowercase letters, numbers, hyphen, or underscore."
            }
        }
        return nil
    }

    public static func isValid(_ raw: String) -> Bool {
        validationError(for: raw) == nil
    }
}

// MARK: - Matching

public struct TextExpansionMatch: Equatable, Sendable {
    public let snippet: TextExpansionSnippet
    public let token: String
    public let replacementRange: Range<String.Index>
    public let boundary: Character?
    public let requiresPreview: Bool

    public init(
        snippet: TextExpansionSnippet,
        token: String,
        replacementRange: Range<String.Index>,
        boundary: Character?,
        requiresPreview: Bool
    ) {
        self.snippet = snippet
        self.token = token
        self.replacementRange = replacementRange
        self.boundary = boundary
        self.requiresPreview = requiresPreview
    }
}

public struct TextExpansionResult: Equatable, Sendable {
    public let text: String
    public let match: TextExpansionMatch
}

public enum TextExpansionMatcher {
    public static func isBoundary(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return true }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        if CharacterSet.punctuationCharacters.contains(scalar) {
            return scalar != "&" && scalar != "_" && scalar != "-"
        }
        return false
    }

    public static func match(
        in text: String,
        snippets rawSnippets: [TextExpansionSnippet],
        surface: TextExpansionSurface,
        bundleIdentifier: String? = nil,
        threadID: String? = nil,
        cursor: String.Index? = nil,
        expandWhenUnambiguous: Bool = true
    ) -> TextExpansionMatch? {
        let cursor = cursor ?? text.endIndex
        guard cursor > text.startIndex else { return nil }

        let snippets = rawSnippets
            .filter { $0.isActive && $0.scope.allows(surface: surface, bundleIdentifier: bundleIdentifier, threadID: threadID) }
        guard snippets.isEmpty == false else { return nil }

        let prefixText = text[..<cursor]
        guard let last = prefixText.last else { return nil }
        let hasBoundary = isBoundary(last)
        let tokenEnd = hasBoundary ? prefixText.index(before: prefixText.endIndex) : prefixText.endIndex
        guard tokenEnd > prefixText.startIndex else { return nil }

        var tokenStart = tokenEnd
        while tokenStart > prefixText.startIndex {
            let previous = prefixText.index(before: tokenStart)
            if isBoundary(prefixText[previous]) {
                break
            }
            tokenStart = previous
        }

        let token = String(prefixText[tokenStart..<tokenEnd])
        guard token.hasPrefix(TextExpansionTrigger.prefix) else { return nil }
        let canonical = TextExpansionTrigger.canonicalName(token)
        guard canonical.isEmpty == false else { return nil }

        let activeTriggers = snippets.map(\.trigger)
        guard let snippet = snippets.first(where: { $0.trigger == canonical }) else { return nil }

        if !hasBoundary && expandWhenUnambiguous == false {
            return nil
        }
        if !hasBoundary && activeTriggers.contains(where: { $0 != canonical && $0.hasPrefix(canonical) }) {
            return nil
        }

        return TextExpansionMatch(
            snippet: snippet,
            token: token,
            replacementRange: tokenStart..<tokenEnd,
            boundary: hasBoundary ? last : nil,
            requiresPreview: snippet.mode == .llmRewrite
        )
    }

    public static func replacingMatch(in text: String, match: TextExpansionMatch, replacement: String? = nil) -> String {
        var copy = text
        copy.replaceSubrange(match.replacementRange, with: replacement ?? match.snippet.body)
        return copy
    }

    public static func expandStaticIfAvailable(
        in text: String,
        snippets: [TextExpansionSnippet],
        surface: TextExpansionSurface,
        bundleIdentifier: String? = nil,
        threadID: String? = nil,
        cursor: String.Index? = nil,
        expandWhenUnambiguous: Bool = true
    ) -> TextExpansionResult? {
        guard let match = match(
            in: text,
            snippets: snippets,
            surface: surface,
            bundleIdentifier: bundleIdentifier,
            threadID: threadID,
            cursor: cursor,
            expandWhenUnambiguous: expandWhenUnambiguous
        ), match.requiresPreview == false else {
            return nil
        }
        return TextExpansionResult(text: replacingMatch(in: text, match: match), match: match)
    }
}

// MARK: - LLM Context Pack

public struct TextExpansionContextMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct TextExpansionContextPack: Codable, Equatable, Sendable {
    public var surface: TextExpansionSurface
    public var threadID: String?
    public var title: String?
    public var messages: [TextExpansionContextMessage]
    public var maxCharacters: Int

    public init(
        surface: TextExpansionSurface,
        threadID: String? = nil,
        title: String? = nil,
        messages: [TextExpansionContextMessage] = [],
        maxCharacters: Int = 2_000
    ) {
        self.surface = surface
        self.threadID = threadID
        self.title = title
        self.messages = messages
        self.maxCharacters = maxCharacters
    }

    public var plainTextSummary: String {
        var lines: [String] = []
        if let title, !title.isEmpty {
            lines.append("Thread: \(title)")
        }
        if let threadID, !threadID.isEmpty {
            lines.append("Thread ID: \(threadID)")
        }
        for message in messages.suffix(12) {
            let trimmed = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append("\(message.role): \(String(trimmed.prefix(1_200)))")
        }
        return lines.joined(separator: "\n")
    }
}

public enum TextExpansionPromptBuilder {
    public static func buildSystemPrompt(maxCharacters: Int) -> String {
        """
        Goal: Rewrite the saved snippet into text that fits the current thread context.

        Success means:
        - Preserve the saved snippet's intent, facts, commitments, and user voice.
        - Use the thread context to adjust salutation, references, tense, and specificity.
        - Return plaintext that is ready to insert.
        - Keep the response within \(maxCharacters) characters unless the snippet asks for a longer form.

        Stop when: One insertion-ready response is produced.
        """
    }

    public static func buildUserPrompt(snippetBody: String, context: TextExpansionContextPack) -> String {
        """
        Saved snippet:
        \(snippetBody)

        Thread context:
        \(context.plainTextSummary.isEmpty ? "No thread context is available for this insertion surface." : context.plainTextSummary)

        Write the final insertion text only.
        """
    }
}
