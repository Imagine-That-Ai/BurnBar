import Foundation

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif

extension CursorConnectorManager {
    static func supportedModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return ConnectorProvider.allCases.contains { supportedModel(normalized, provider: $0) }
    }

    static func supportedModel(_ model: String, provider: ConnectorProvider?) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if let provider {
            if OpenBurnBarConnectorCatalogLookup.shared.supportsModel(named: normalized, providerID: provider.rawValue) {
                return true
            }

            guard !OpenBurnBarConnectorCatalogLookup.shared.isCatalogAvailable else {
                return false
            }

            let lowercased = normalized.lowercased()
            switch provider {
            case .zai:
                return lowercased.contains("glm") || lowercased.contains("z.ai")
            case .minimax:
                return lowercased.contains("minimax")
            case .ollama:
                return lowercased.contains("ollama")
                    || lowercased.contains(":cloud")
                    || lowercased.contains("-cloud")
                    || lowercased.contains("gpt-oss")
                    || lowercased.contains("deepseek")
                    || lowercased.contains("qwen")
            }
        }

        return Self.supportedModel(normalized)
    }

    static func provider(forBaseURL baseURL: String) -> ConnectorProvider? {
        if let catalog = OpenBurnBarConnectorCatalogLookup.shared.provider(forBaseURL: baseURL) {
            return ConnectorProvider(rawValue: catalog.id)
        }
        let normalized = baseURL.lowercased()
        if normalized.contains("z.ai") {
            return .zai
        }
        if normalized.contains("minimax") {
            return .minimax
        }
        if normalized.contains("ollama") || normalized.contains("localhost:11434") || normalized.contains("127.0.0.1:11434") {
            return .ollama
        }
        return nil
    }

}
