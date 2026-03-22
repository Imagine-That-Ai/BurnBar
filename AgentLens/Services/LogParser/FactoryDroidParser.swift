import Foundation

// MARK: - Factory Droid Parser

final class FactoryDroidParser: LogParser {
    let provider: AgentProvider = .factory
    
    private let fileManager = FileManager.default
    
    func parse() async throws -> [TokenUsage] {
        let sessionsPath = (provider.logDirectory as NSString).expandingTildeInPath
        let sessionsURL = URL(fileURLWithPath: sessionsPath)
        
        guard fileManager.fileExists(atPath: sessionsPath) else {
            print("Factory Droid sessions directory not found at: \(sessionsPath)")
            return []
        }
        
        var usages: [TokenUsage] = []
        
        // Iterate through project directories
        let projectDirs = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
        
        for projectDir in projectDirs {
            let projectName = projectDir.lastPathComponent
                .replacingOccurrences(of: "-Users-", with: "~/")
                .replacingOccurrences(of: "-", with: "/")
            
            // Find all .jsonl session files and their corresponding .settings.json
            let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
            
            // Group by session ID
            var sessionFiles: [String: (jsonl: URL, settings: URL?)] = [:]
            
            for file in files ?? [] {
                let filename = file.lastPathComponent
                let baseName = filename.replacingOccurrences(of: ".jsonl", with: "")
                                       .replacingOccurrences(of: ".settings.json", with: "")
                
                if filename.hasSuffix(".jsonl") {
                    if sessionFiles[baseName] == nil {
                        sessionFiles[baseName] = (jsonl: file, settings: nil)
                    } else {
                        sessionFiles[baseName]?.jsonl = file
                    }
                } else if filename.hasSuffix(".settings.json") {
                    if sessionFiles[baseName] == nil {
                        sessionFiles[baseName] = (jsonl: file, settings: file)
                    } else {
                        sessionFiles[baseName]?.settings = file
                    }
                }
            }
            
            // Parse each session
            for (sessionId, files) in sessionFiles {
                if let usage = try? await parseSession(
                    sessionId: sessionId,
                    jsonlFile: files.jsonl,
                    settingsFile: files.settings,
                    projectName: projectName
                ) {
                    usages.append(usage)
                }
            }
        }
        
        return usages
    }
    
    private func parseSession(
        sessionId: String,
        jsonlFile: URL,
        settingsFile: URL?,
        projectName: String
    ) async throws -> TokenUsage? {
        // Read settings file for token totals
        var tokenData: (
            input: Int,
            output: Int,
            cacheCreation: Int,
            cacheRead: Int,
            model: String,
            startTime: Date?,
            endTime: Date?
        ) = (0, 0, 0, 0, "unknown", nil, nil)
        
        if let settingsFile = settingsFile {
            if let data = try? Data(contentsOf: settingsFile),
               let settings = try? JSONDecoder().decode(FactorySettings.self, from: data) {
                tokenData.input = settings.tokenUsage?.inputTokens ?? 0
                tokenData.output = settings.tokenUsage?.outputTokens ?? 0
                tokenData.cacheCreation = settings.tokenUsage?.cacheCreationTokens ?? 0
                tokenData.cacheRead = settings.tokenUsage?.cacheReadTokens ?? 0
                tokenData.model = settings.model ?? "unknown"
            }
        }
        
        // Read JSONL file for timestamps
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        
        if let handle = try? FileHandle(forReadingFrom: jsonlFile) {
            defer { try? handle.close() }
            
            // Read first line for start time
            if let firstLine = handle.readLine() {
                if let data = firstLine.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let ts = json["timestamp"] as? String {
                        firstTimestamp = ISO8601DateFormatter().date(from: ts)
                    }
                    // Also check for session_start type
                    if json["type"] as? String == "session_start",
                       let ts = json["timestamp"] as? String {
                        firstTimestamp = ISO8601DateFormatter().date(from: ts) ?? firstTimestamp
                    }
                }
            }
            
            // Seek to end and read backwards for last line
            if let lastLine = try? handle.readLastLine() {
                if let data = lastLine.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ts = json["timestamp"] as? String {
                    lastTimestamp = ISO8601DateFormatter().date(from: ts)
                }
            }
        }
        
        let startTime = firstTimestamp ?? Date()
        let endTime = lastTimestamp ?? startTime
        
        // Calculate cost (approximate pricing)
        let cost = calculateCost(
            inputTokens: tokenData.input,
            outputTokens: tokenData.output,
            cacheCreationTokens: tokenData.cacheCreation,
            cacheReadTokens: tokenData.cacheRead,
            model: tokenData.model
        )
        
        // Skip sessions with no activity
        guard tokenData.input > 0 || tokenData.output > 0 else { return nil }
        
        return TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: projectName,
            model: tokenData.model,
            inputTokens: tokenData.input,
            outputTokens: tokenData.output,
            cacheCreationTokens: tokenData.cacheCreation,
            cacheReadTokens: tokenData.cacheRead,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime
        )
    }
    
    private func calculateCost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        model: String
    ) -> Double {
        // Approximate pricing (these vary by model, using Claude-like pricing as baseline)
        let lowercasedModel = model.lowercased()
        
        let inputCost: Double
        let outputCost: Double
        let cacheCreationCost: Double
        let cacheReadCost: Double
        
        if lowercasedModel.contains("opus") {
            inputCost = 0.000015      // $15/1M tokens
            outputCost = 0.000075     // $75/1M tokens
            cacheCreationCost = 0.00001875
            cacheReadCost = 0.0000015
        } else if lowercasedModel.contains("sonnet") {
            inputCost = 0.000003      // $3/1M tokens
            outputCost = 0.000015     // $15/1M tokens
            cacheCreationCost = 0.00000375
            cacheReadCost = 0.0000003
        } else if lowercasedModel.contains("haiku") {
            inputCost = 0.00000025    // $0.25/1M tokens
            outputCost = 0.00000125   // $1.25/1M tokens
            cacheCreationCost = 0.0000003125
            cacheReadCost = 0.00000003
        } else if lowercasedModel.contains("glm") || lowercasedModel.contains("z.ai") {
            // GLM models - approximate
            inputCost = 0.000001
            outputCost = 0.000002
            cacheCreationCost = 0
            cacheReadCost = 0
        } else {
            // Default (sonnet-like)
            inputCost = 0.000003
            outputCost = 0.000015
            cacheCreationCost = 0.00000375
            cacheReadCost = 0.0000003
        }
        
        return Double(inputTokens) * inputCost
             + Double(outputTokens) * outputCost
             + Double(cacheCreationTokens) * cacheCreationCost
             + Double(cacheReadTokens) * cacheReadCost
    }
}

// MARK: - Factory Settings Model

private struct FactorySettings: Codable {
    let model: String?
    let tokenUsage: TokenUsageData?
    
    struct TokenUsageData: Codable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let thinkingTokens: Int?
    }
}
