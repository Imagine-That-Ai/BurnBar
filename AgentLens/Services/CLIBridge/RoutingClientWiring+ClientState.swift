import CryptoKit
import Foundation

extension RoutingClientWiring {

    func installedCodexOpenBurnBarModelIDs() -> [String] {
        let url = codexModelCatalogURL()
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url), // try?-ok(optional catalog read, empty fallback)
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(optional catalog parse, empty fallback)
              let models = root["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { row in
            guard let slug = row["slug"] as? String,
                  slug.lowercased().hasPrefix("openburnbar/") else {
                return nil
            }
            return String(slug.dropFirst("openburnbar/".count))
        }
        .uniquedPreservingOrder()
    }

    func installedClaudeOpenBurnBarModelIDs() -> [String] {
        let url = configURL(for: .claudeCode)
        guard let root = try? readJSONObject(at: url), // try?-ok(optional Claude config read, empty fallback)
              let env = root["env"] as? [String: Any],
              let ids = env[Self.claudeCatalogIDsKey] as? String else {
            return []
        }
        return ids
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniquedPreservingOrder()
    }

    func installedClaudeCatalogFingerprint() -> String? {
        let url = configURL(for: .claudeCode)
        guard let root = try? readJSONObject(at: url), // try?-ok(optional Claude config read, nil fallback)
              let env = root["env"] as? [String: Any] else {
            return nil
        }
        return (env[Self.claudeCatalogFingerprintKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    func modelCatalogFingerprint(
        modelIDs: [String],
        gateway: RoutingClientGateway
    ) -> String {
        let material = [
            gateway.baseURL,
            gateway.effectiveClientToken,
            modelIDs.joined(separator: "\n")
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func mergedClaudeCustomHeaders(existing: String?) -> String {
        var lines = existing?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("x-openburnbar-client:") }
            ?? []
        lines.append(Self.claudeCodeClientHeader)
        return lines.joined(separator: "\n")
    }

    static func removingOpenBurnBarClaudeHeaders(from existing: String?) -> String? {
        let lines = existing?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("x-openburnbar-client:") }
            ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func tomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
