import Foundation

// MARK: - Parse Result

struct ParseResult: Sendable {
    let usages: [TokenUsage]
    let conversations: [ConversationRecord]
}

// MARK: - Log Parser Protocol

protocol LogParser: Sendable {
    var provider: AgentProvider { get }
    func parse() async throws -> ParseResult
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
