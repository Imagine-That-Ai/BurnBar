import Foundation

// MARK: - Usage Aggregator

@Observable
@MainActor
final class UsageAggregator {
    private let dataStore: DataStore
    private let parsers: [AgentProvider: any LogParser]
    
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var errors: [AgentProvider: String] = [:]
    
    init(dataStore: DataStore) {
        self.dataStore = dataStore
        self.parsers = [
            .factory: FactoryDroidParser(),
            .claudeCode: ClaudeCodeParser(),
            .copilot: CopilotParser(),
            .aider: AiderParser(),
            .cursor: CursorImporter()
        ]
    }
    
    // MARK: - Refresh All
    
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errors = [:]
        
        var allUsages: [TokenUsage] = []
        
        await withTaskGroup(of: (AgentProvider, Result<[TokenUsage], Error>).self) { group in
            for (provider, parser) in parsers {
                group.addTask {
                    do {
                        let usages = try await parser.parse()
                        return (provider, .success(usages))
                    } catch {
                        return (provider, .failure(error))
                    }
                }
            }
            
            for await (provider, result) in group {
                switch result {
                case .success(let usages):
                    allUsages.append(contentsOf: usages)
                case .failure(let error):
                    errors[provider] = error.localizedDescription
                    print("Failed to parse \(provider.rawValue): \(error)")
                }
            }
        }
        
        // Store all usages
        do {
            try dataStore.insert(allUsages)
            await dataStore.refresh()
            lastRefresh = Date()
        } catch {
            print("Failed to store usages: \(error)")
        }
        
        isRefreshing = false
    }
    
    // MARK: - Refresh Single Provider
    
    func refresh(provider: AgentProvider) async {
        guard let parser = parsers[provider] else { return }
        
        do {
            let usages = try await parser.parse()
            try dataStore.insert(usages)
            await dataStore.refresh()
            errors.removeValue(forKey: provider)
        } catch {
            errors[provider] = error.localizedDescription
        }
    }
}

// MARK: - Copilot Parser

final class CopilotParser: LogParser {
    let provider: AgentProvider = .copilot
    
    private let fileManager = FileManager.default
    
    func parse() async throws -> [TokenUsage] {
        let basePath = (provider.logDirectory as NSString).expandingTildeInPath
        
        // Copilot stores data in various locations
        // For now, return empty as Copilot API access requires special setup
        print("Copilot parser: \(basePath)")
        return []
    }
}

// MARK: - Aider Parser

final class AiderParser: LogParser {
    let provider: AgentProvider = .aider
    
    private let fileManager = FileManager.default
    
    func parse() async throws -> [TokenUsage] {
        let basePath = (provider.logDirectory as NSString).expandingTildeInPath
        
        // Aider stores history in ~/.aider.chat.history.db (SQLite)
        // For now, return empty until we implement SQLite parsing
        print("Aider parser: \(basePath)")
        return []
    }
}

// MARK: - Cursor Importer (Manual Import Only)

final class CursorImporter: LogParser {
    let provider: AgentProvider = .cursor
    
    func parse() async throws -> [TokenUsage] {
        // Cursor requires manual import - no automatic log parsing
        return []
    }
    
    func importFromFile(_ url: URL) async throws -> [TokenUsage] {
        // Import from JSON/CSV file
        let data = try Data(contentsOf: url)
        
        if url.pathExtension == "json" {
            return try parseJSON(data)
        } else if url.pathExtension == "csv" {
            return try parseCSV(data)
        }
        
        return []
    }
    
    private func parseJSON(_ data: Data) throws -> [TokenUsage] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        
        return json.compactMap { entry -> TokenUsage? in
            guard let inputTokens = entry["inputTokens"] as? Int,
                  let outputTokens = entry["outputTokens"] as? Int,
                  let timestamp = entry["timestamp"] as? String else { return nil }
            
            let date = ISO8601DateFormatter().date(from: timestamp) ?? Date()
            
            return TokenUsage(
                provider: .cursor,
                sessionId: UUID().uuidString,
                projectName: entry["project"] as? String ?? "Unknown",
                model: entry["model"] as? String ?? "cursor",
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationTokens: entry["cacheCreationTokens"] as? Int ?? 0,
                cacheReadTokens: entry["cacheReadTokens"] as? Int ?? 0,
                costUSD: entry["cost"] as? Double ?? 0,
                startTime: date,
                endTime: date
            )
        }
    }
    
    private func parseCSV(_ data: Data) throws -> [TokenUsage] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }
        
        let headers = lines[0].components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        
        var usages: [TokenUsage] = []
        
        for i in 1..<lines.count {
            let values = lines[i].components(separatedBy: ",")
            guard values.count >= headers.count else { continue }
            
            var dict: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                dict[header] = values[index].trimmingCharacters(in: .whitespaces)
            }
            
            guard let inputTokens = Int(dict["inputtokens"] ?? "0"),
                  let outputTokens = Int(dict["outputtokens"] ?? "0") else { continue }
            
            let dateStr = dict["timestamp"] ?? dict["date"] ?? ""
            let date = ISO8601DateFormatter().date(from: dateStr) ?? Date()
            
            let usage = TokenUsage(
                provider: .cursor,
                sessionId: UUID().uuidString,
                projectName: dict["project"] ?? "Unknown",
                model: dict["model"] ?? "cursor",
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationTokens: Int(dict["cachecreationtokens"] ?? "0") ?? 0,
                cacheReadTokens: Int(dict["cachereadtokens"] ?? "0") ?? 0,
                costUSD: Double(dict["cost"] ?? "0") ?? 0,
                startTime: date,
                endTime: date
            )
            usages.append(usage)
        }
        
        return usages
    }
}
