import Foundation

// MARK: - Parse Result

struct ParseResult: Sendable {
    let usages: [TokenUsage]
    let conversations: [ConversationRecord]
    /// Parser-specific health captured during this parse. Parsers that expose
    /// richer diagnostics (currently Pi and Grok CLI) populate it so the
    /// registered UsageAggregator surface cannot turn a degraded transcript
    /// into a misleading healthy provider state.
    let transcriptParseHealth: TranscriptParseHealth?

    init(
        usages: [TokenUsage],
        conversations: [ConversationRecord],
        transcriptParseHealth: TranscriptParseHealth? = nil
    ) {
        self.usages = usages
        self.conversations = conversations
        self.transcriptParseHealth = transcriptParseHealth
    }
}

// MARK: - Log Parser Protocol

protocol LogParser: Sendable {
    var provider: AgentProvider { get }
    func parse() async throws -> ParseResult
}

// MARK: - Transcript Parse Health

/// Typed parse-health surface for the M2 usage parsers (VAL-PROV-007).
///
/// Each parser records per-parse counts on `lastParseHealth`:
/// - `itemsScanned`: transcript files (Pi) or session directories (Grok CLI) examined;
/// - `itemsParsed`: items that produced a `TokenUsage` row;
/// - `itemsSkipped`: items that produced no row (missing/empty/blank files, no
///   parseable timestamps, no usage data);
/// - `malformedLines`: JSON lines that could not be decoded (truncated JSON,
///   garbage bytes, wrong shape). A non-zero count degrades the parse
///   (`isDegraded == true`) without dropping valid rows.
struct TranscriptParseHealth: Equatable, Sendable {
    var itemsScanned = 0
    var itemsParsed = 0
    var itemsSkipped = 0
    var malformedLines = 0

    var isDegraded: Bool { malformedLines > 0 }

    var summary: String {
        "scanned=\(itemsScanned) parsed=\(itemsParsed) skipped=\(itemsSkipped) malformedLines=\(malformedLines)"
    }
}

// MARK: - FileHandle Extensions

extension FileHandle {
    /// Buffered UTF-8 line reader for log files. This is substantially faster than byte-at-a-time reads.
    func readAllUTF8Lines() -> [String] {
        let data = readDataToEndOfFile()
        guard !data.isEmpty,
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        return content.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Lossy UTF-8 line reader: invalid byte sequences become U+FFFD instead
    /// of failing the whole-file decode, so a torn multi-byte tail degrades to
    /// a malformed line (skipped, counted in parse health) while valid rows
    /// are preserved (VAL-PROV-007/014). Used by the M2 transcript parsers.
    func readAllUTF8LinesLossy() -> [String] {
        let data = readDataToEndOfFile()
        guard !data.isEmpty else { return [] }
        // Lossy decode is intentional: invalid bytes become U+FFFD so a torn
        // multi-byte tail degrades to a skipped malformed line instead of
        // failing the whole-file decode (VAL-PROV-007/014).
        // swiftlint:disable:next optional_data_string_conversion
        let content = String(decoding: data, as: UTF8.self)
        return content.split(whereSeparator: \.isNewline).map(String.init)
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
