import Foundation
import OpenBurnBarCore

// MARK: - Parse Result

struct ParseResult: Sendable {
    let usages: [TokenUsage]
    let conversations: [ConversationRecord]
}

struct LogParseOptions: Sendable {
    var includeConversationBodies: Bool

    static let `default` = LogParseOptions(includeConversationBodies: true)
}

// MARK: - Log Parser Protocol

protocol LogParser: LogParserProtocol {
    func parse() async throws -> ParseResult
    func parse(options: LogParseOptions) async throws -> ParseResult
}

extension LogParser {
    func parse(options: LogParseOptions) async throws -> ParseResult {
        let result = try await parse()
        guard options.includeConversationBodies else {
            return ParseResult(usages: result.usages, conversations: [])
        }
        return result
    }
}

struct ParserConversationCacheScrubber {
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths

    init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
    }

    func scrubKnownParserCaches() {
        for cacheURL in knownCacheURLs() {
            scrubCache(at: cacheURL)
        }
    }

    private func knownCacheURLs() -> [URL] {
        var urls = [
            appPaths.supportDirectory.appendingPathComponent("codex_parser_cache.json"),
            appPaths.claudeCodeParserCacheURL,
            appPaths.factoryDroidParserCacheURL,
            appPaths.junieParserCacheURL
        ]

        if let dynamicURLs = try? fileManager.contentsOfDirectory( // try?-ok(optional cache directory scan)
            at: appPaths.supportDirectory,
            includingPropertiesForKeys: nil
        ) {
            urls.append(
                contentsOf: dynamicURLs.filter {
                    $0.lastPathComponent.hasPrefix("model_filter_parser_")
                        && $0.pathExtension == "json"
                }
            )
        }

        return urls
    }

    private func scrubCache(at cacheURL: URL) {
        guard fileManager.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL), // try?-ok(best-effort cache read)
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(best-effort cache decode)
              var entries = root["fileEntries"] as? [String: Any] else {
            return
        }

        var mutated = false
        for (key, value) in entries {
            guard var entry = value as? [String: Any],
                  entry["conversation"] != nil else { continue }
            entry["conversation"] = NSNull()
            entries[key] = entry
            mutated = true
        }

        guard mutated else { return }
        root["fileEntries"] = entries
        guard let scrubbedData = try? JSONSerialization.data( // try?-ok(best-effort cache encode)
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }
        try? scrubbedData.write(to: cacheURL, options: .atomic) // try?-ok(best-effort cache rewrite)
    }
}

// MARK: - FileHandle Extensions

extension FileHandle {
    /// Buffered UTF-8 line reader for log files. Returns a lazy sequence so
    /// parsers do not load and split multi-megabyte logs into memory at startup.
    func readAllUTF8Lines() -> BufferedLineSequence {
        BufferedLineSequence(fileHandle: self)
    }

    func readLine() -> String? {
        var data = Data()
        var byte = readData(ofLength: 1)
        // EOF before reading any byte should terminate line iteration.
        if byte.isEmpty {
            return nil
        }
        
        while !byte.isEmpty {
            if byte.first == Character("\n").asciiValue {
                break
            }
            data.append(byte)
            byte = readData(ofLength: 1)
        }
        
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }
    
    func readLastLine() throws -> String? {
        // Read last ~4KB and find last newline
        seek(toFileOffset: max(0, offsetInFile - 4096))
        let data = readData(ofLength: 4096)
        
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.last
    }
}
