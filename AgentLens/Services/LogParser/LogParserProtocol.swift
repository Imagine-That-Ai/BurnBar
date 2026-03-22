import Foundation

// MARK: - Log Parser Protocol

protocol LogParser {
    var provider: AgentProvider { get }
    func parse() async throws -> [TokenUsage]
}

// MARK: - FileHandle Extensions

extension FileHandle {
    func readLine() -> String? {
        var data = Data()
        var byte = readData(ofLength: 1)
        
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
