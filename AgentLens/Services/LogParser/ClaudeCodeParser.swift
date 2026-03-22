import Foundation

// MARK: - Claude Code Parser

final class ClaudeCodeParser: LogParser {
    let provider: AgentProvider = .claudeCode
    
    private let fileManager = FileManager.default
    
    func parse() async throws -> [TokenUsage] {
        // Try using ccusage CLI first if available
        if let usages = try? await parseViaCcusage(), !usages.isEmpty {
            return usages
        }
        
        // Fallback to direct JSONL parsing
        return try await parseDirectly()
    }
    
    // MARK: - CCUsage CLI Parsing
    
    private func parseViaCcusage() async throws -> [TokenUsage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "ccusage@latest", "daily", "--json", "--instances"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else { return [] }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        
        var usages: [TokenUsage] = []
        
        // Parse projects
        if let projects = json["projects"] as? [String: [[String: Any]]] {
            for (projectName, dailyEntries) in projects {
                for entry in dailyEntries {
                    guard let dateStr = entry["date"] as? String else { continue }
                    
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd"
                    guard let date = dateFormatter.date(from: dateStr) else { continue }
                    
                    let modelsUsed = entry["modelsUsed"] as? [String]
                    let usage = TokenUsage(
                        provider: .claudeCode,
                        sessionId: "\(projectName)-\(dateStr)",
                        projectName: projectName,
                        model: modelsUsed?.first ?? "claude",
                        inputTokens: entry["inputTokens"] as? Int ?? 0,
                        outputTokens: entry["outputTokens"] as? Int ?? 0,
                        cacheCreationTokens: entry["cacheCreationTokens"] as? Int ?? 0,
                        cacheReadTokens: entry["cacheReadTokens"] as? Int ?? 0,
                        costUSD: entry["totalCost"] as? Double ?? 0,
                        startTime: date,
                        endTime: date
                    )
                    usages.append(usage)
                }
            }
        }
        
        return usages
    }
    
    // MARK: - Direct JSONL Parsing
    
    private func parseDirectly() async throws -> [TokenUsage] {
        let projectsPath = (provider.logDirectory as NSString).expandingTildeInPath
        let projectsURL = URL(fileURLWithPath: projectsPath)
        
        guard fileManager.fileExists(atPath: projectsPath) else {
            print("Claude Code projects directory not found at: \(projectsPath)")
            return []
        }
        
        var usages: [TokenUsage] = []
        var sessionData: [String: ClaudeSessionAccumulator] = [:]
        
        // Iterate through project directories
        let projectDirs = try fileManager.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
        
        for projectDir in projectDirs {
            let projectName = projectDir.lastPathComponent
                .replacingOccurrences(of: "-Users-", with: "~/")
                .replacingOccurrences(of: "-", with: "/")
            
            // Find all .jsonl session files
            let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
            let jsonlFiles = files?.filter { $0.pathExtension == "jsonl" } ?? []
            
            for jsonlFile in jsonlFiles {
                let sessionId = jsonlFile.deletingPathExtension().lastPathComponent
                
                if let accumulator = try? parseClaudeSession(
                    file: jsonlFile,
                    sessionId: sessionId,
                    projectName: projectName
                ) {
                    sessionData[sessionId] = accumulator
                }
            }
        }
        
        // Convert accumulators to TokenUsage
        for (sessionId, acc) in sessionData {
            guard acc.inputTokens > 0 || acc.outputTokens > 0 else { continue }
            
            let usage = TokenUsage(
                provider: .claudeCode,
                sessionId: sessionId,
                projectName: acc.projectName,
                model: acc.models.first ?? "claude",
                inputTokens: acc.inputTokens,
                outputTokens: acc.outputTokens,
                cacheCreationTokens: acc.cacheCreationTokens,
                cacheReadTokens: acc.cacheReadTokens,
                costUSD: acc.totalCost,
                startTime: acc.startTime ?? Date(),
                endTime: acc.endTime ?? Date()
            )
            usages.append(usage)
        }
        
        return usages
    }
    
    private func parseClaudeSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) throws -> ClaudeSessionAccumulator? {
        var acc = ClaudeSessionAccumulator(projectName: projectName)
        
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        
        while true {
            guard let line = handle.readLine() else { break }
            guard let data = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            
            // Parse timestamp
            if let timestamp = json["timestamp"] as? String {
                let date = ISO8601DateFormatter().date(from: timestamp)
                if acc.startTime == nil { acc.startTime = date }
                acc.endTime = date
            }
            
            // Parse message for usage data
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                acc.inputTokens += usage["input_tokens"] as? Int ?? 0
                acc.outputTokens += usage["output_tokens"] as? Int ?? 0
                acc.cacheCreationTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
                acc.cacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0
                
                if let model = message["model"] as? String {
                    acc.models.insert(model)
                }
            }
            
            // Calculate cost from message
            // Claude Code stores cost in the message, we need to estimate
        }
        
        // Calculate cost based on models
        acc.totalCost = calculateClaudeCost(
            inputTokens: acc.inputTokens,
            outputTokens: acc.outputTokens,
            cacheCreationTokens: acc.cacheCreationTokens,
            cacheReadTokens: acc.cacheReadTokens,
            models: Array(acc.models)
        )
        
        return acc
    }
    
    private func calculateClaudeCost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        models: [String]
    ) -> Double {
        let model = models.first?.lowercased() ?? ""
        
        let inputCost: Double
        let outputCost: Double
        let cacheCreationCost: Double
        let cacheReadCost: Double
        
        if model.contains("opus") {
            inputCost = 0.000015
            outputCost = 0.000075
            cacheCreationCost = 0.00001875
            cacheReadCost = 0.0000015
        } else if model.contains("sonnet") {
            inputCost = 0.000003
            outputCost = 0.000015
            cacheCreationCost = 0.00000375
            cacheReadCost = 0.0000003
        } else if model.contains("haiku") {
            inputCost = 0.00000025
            outputCost = 0.00000125
            cacheCreationCost = 0.0000003125
            cacheReadCost = 0.00000003
        } else {
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

// MARK: - Session Accumulator

private struct ClaudeSessionAccumulator {
    let projectName: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var totalCost: Double = 0
    var models: Set<String> = []
    var startTime: Date?
    var endTime: Date?
}
