import Foundation

/// Swaps private identifiers for opaque tokens on the way out to a model, and
/// swaps them back on the way in.
///
/// The problem this solves: the deterministic copy the model is asked to improve
/// already contains sentences like "BurnBar took about a third of your agent
/// work". Hashing the name would leave the model writing about a hash. Tokenizing
/// lets it write natural prose around a placeholder that is restored locally, so
/// the finished card reads correctly and the name never leaves the device.
///
/// Project names are tokenized because they are the genuinely private identifier
/// here — repository names, client names, employer names. Model and provider
/// names are vendor product names and are sent as-is; withholding them would
/// cost real copy quality ("your most-used model" is a worse card than "Claude
/// Opus 5 handled 41% of your sessions") for no privacy gain, since the app's
/// whole purpose already implies which vendors are in use.
public struct RecapRedaction: Sendable {

    private var tokenByValue: [String: String] = [:]
    private var valueByToken: [String: String] = [:]
    /// Longest first, so "BurnBar Mobile" is replaced before "BurnBar".
    private var orderedValues: [String] = []

    public init() {}

    public init(projectNames: [String]) {
        for name in projectNames {
            _ = register(name)
        }
    }

    public var isEmpty: Bool { tokenByValue.isEmpty }

    /// The map a caller can log or assert against in tests.
    public var tokens: [String: String] { valueByToken }

    @discardableResult
    public mutating func register(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Every non-empty name is tokenized, including two-letter ones like
        // "fx". Skipping short names used to be the guard against matching
        // inside unrelated words — but it meant the shortest project names, the
        // ones most likely to be an employer or client code, went out in clear
        // text. Word-boundary matching handles the collision instead.
        guard !trimmed.isEmpty else { return nil }
        if let existing = tokenByValue[trimmed] { return existing }
        let token = "{project\(tokenByValue.count + 1)}"
        tokenByValue[trimmed] = token
        valueByToken[token] = trimmed
        orderedValues = tokenByValue.keys.sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        return token
    }

    /// Replaces every registered value with its token.
    ///
    /// Matches on word boundaries so a short name cannot corrupt an unrelated
    /// word — "fx" replaces the standalone token, never the middle of "prefix".
    public func redact(_ text: String) -> String {
        guard !orderedValues.isEmpty else { return text }
        var output = text
        for value in orderedValues {
            guard let token = tokenByValue[value] else { continue }
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: value) + "(?![A-Za-z0-9])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                output = output.replacingOccurrences(of: value, with: token, options: [.caseInsensitive])
                continue
            }
            output = regex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output),
                withTemplate: NSRegularExpression.escapedTemplate(for: token)
            )
        }
        return output
    }

    /// Puts the real values back.
    public func restore(_ text: String) -> String {
        guard !valueByToken.isEmpty else { return text }
        var output = text
        for (token, value) in valueByToken {
            output = output.replacingOccurrences(of: token, with: value)
        }
        return output
    }

    /// True when `text` still contains a token-shaped fragment after
    /// restoration — meaning the model invented a placeholder we cannot resolve.
    /// Such copy is rejected rather than shipped with `{project7}` visible.
    public func hasUnresolvedTokens(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\{project\\d+\\}") else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
