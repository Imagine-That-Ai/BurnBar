import Foundation

public struct HermesSourceLink: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let displayHost: String

    public init(title: String, url: URL, displayHost: String) {
        self.id = url.absoluteString
        self.title = title
        self.url = url
        self.displayHost = displayHost
    }
}

public enum HermesSourceLinkExtractor {
    public static func extract(from source: String, limit: Int = 6) -> [HermesSourceLink] {
        guard limit > 0, !source.isEmpty else { return [] }

        var links: [HermesSourceLink] = []
        var seen = Set<String>()

        func append(urlString: String, title: String?) {
            guard links.count < limit,
                  let url = sourceURL(from: urlString) else { return }
            let dedupeKey = normalizedURLKey(url)
            guard seen.insert(dedupeKey).inserted else { return }
            let host = displayHost(for: url)
            let resolvedTitle = cleanedTitle(title) ?? host
            links.append(HermesSourceLink(title: resolvedTitle, url: url, displayHost: host))
        }

        for match in markdownLinks(in: source) {
            append(urlString: match.urlString, title: match.label)
        }

        for urlString in rawURLs(in: source) {
            append(urlString: urlString, title: nil)
        }

        return links
    }

    public static func collapseExternalLinksForDisplay(in source: String) -> String {
        guard !source.isEmpty else { return source }
        let markdownCollapsed = collapseMarkdownLinks(in: source)
        return collapseRawURLs(in: markdownCollapsed)
    }

    private struct MarkdownLinkMatch {
        let range: Range<String.Index>
        let label: String
        let urlString: String
    }

    private static func markdownLinks(in source: String) -> [MarkdownLinkMatch] {
        var matches: [MarkdownLinkMatch] = []
        var index = source.startIndex

        while index < source.endIndex {
            guard source[index] == "[" else {
                index = source.index(after: index)
                continue
            }
            let escaped = index > source.startIndex && source[source.index(before: index)] == "\\"
            if !escaped, let match = matchMarkdownLink(in: source, startingAt: index) {
                matches.append(match)
                index = match.range.upperBound
            } else {
                index = source.index(after: index)
            }
        }

        return matches
    }

    private static func matchMarkdownLink(
        in source: String,
        startingAt start: String.Index
    ) -> MarkdownLinkMatch? {
        var index = source.index(after: start)
        var label = ""
        var depth = 1

        while index < source.endIndex {
            let character = source[index]
            if character == "\n" { return nil }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            label.append(character)
            index = source.index(after: index)
        }

        guard index < source.endIndex, source[index] == "]" else { return nil }
        let afterCloseBracket = source.index(after: index)
        guard afterCloseBracket < source.endIndex, source[afterCloseBracket] == "(" else { return nil }

        var urlIndex = source.index(after: afterCloseBracket)
        var urlString = ""
        while urlIndex < source.endIndex {
            let character = source[urlIndex]
            if character == ")" { break }
            if character == "\n" { return nil }
            urlString.append(character)
            urlIndex = source.index(after: urlIndex)
        }

        guard urlIndex < source.endIndex, source[urlIndex] == ")" else { return nil }
        let endIndex = source.index(after: urlIndex)
        return MarkdownLinkMatch(range: start..<endIndex, label: label, urlString: urlString)
    }

    private static func rawURLs(in source: String) -> [String] {
        let pattern = #"https?://[^\s<>"'`]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            return trimmedRawURL(String(source[range]))
        }
    }

    private static func collapseMarkdownLinks(in source: String) -> String {
        let matches = markdownLinks(in: source).filter { sourceURL(from: $0.urlString) != nil }
        guard !matches.isEmpty else { return source }

        var output = ""
        var cursor = source.startIndex
        for match in matches {
            output.append(contentsOf: source[cursor..<match.range.lowerBound])
            output.append(cleanedTitle(match.label) ?? displayTitle(for: match.urlString))
            cursor = match.range.upperBound
        }
        output.append(contentsOf: source[cursor..<source.endIndex])
        return output
    }

    private static func collapseRawURLs(in source: String) -> String {
        let urls = rawURLs(in: source)
        guard !urls.isEmpty else { return source }

        var output = source
        for urlString in urls.sorted(by: { $0.count > $1.count }) {
            guard let url = sourceURL(from: urlString) else { continue }
            output = output.replacingOccurrences(of: urlString, with: displayHost(for: url))
        }
        return output
    }

    private static func sourceURL(from raw: String) -> URL? {
        let trimmed = trimmedRawURL(raw)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else { return nil }
        return url
    }

    private static func trimmedRawURL(_ raw: String) -> String {
        var output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = output.last,
              [".", ",", ";", ":", "!", "?", ")", "]", "}"].contains(last) {
            output.removeLast()
        }
        return output
    }

    private static func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let compact = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? nil : compact
    }

    private static func displayTitle(for urlString: String) -> String {
        guard let url = sourceURL(from: urlString) else { return "Source" }
        return displayHost(for: url)
    }

    private static func displayHost(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return "Source" }
        if host.lowercased().hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    private static func normalizedURLKey(_ url: URL) -> String {
        url.absoluteString.lowercased()
    }
}
