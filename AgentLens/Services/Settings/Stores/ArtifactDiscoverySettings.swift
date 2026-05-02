import Foundation

// MARK: - Artifact Discovery Settings

@Observable
@MainActor
final class ArtifactDiscoverySettings {
    private let persistence: SettingsPersistenceCoordinator

    var artifactDiscoveryEnabled: Bool = false {
        didSet { persistence.set(artifactDiscoveryEnabled, forKey: "artifactDiscoveryEnabled") }
    }

    var artifactDiscoveryRegisteredRootsJSON: String = "[]" {
        didSet { persistence.set(artifactDiscoveryRegisteredRootsJSON, forKey: "artifactDiscoveryRegisteredRootsJSON") }
    }

    var artifactDiscoveryAdditionalKnownPatternsJSON: String = "[]" {
        didSet { persistence.set(artifactDiscoveryAdditionalKnownPatternsJSON, forKey: "artifactDiscoveryAdditionalKnownPatternsJSON") }
    }

    var artifactDiscoveryRegisteredRoots: [String] {
        get { Self.decodeJSONStringArray(artifactDiscoveryRegisteredRootsJSON) }
        set { artifactDiscoveryRegisteredRootsJSON = Self.encodeJSONStringArray(newValue) }
    }

    var artifactDiscoveryAdditionalKnownPatterns: [String] {
        get { Self.decodeJSONStringArray(artifactDiscoveryAdditionalKnownPatternsJSON) }
        set { artifactDiscoveryAdditionalKnownPatternsJSON = Self.encodeJSONStringArray(newValue) }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        if persistence.objectExists(forKey: "artifactDiscoveryEnabled") {
            self.artifactDiscoveryEnabled = persistence.bool(forKey: "artifactDiscoveryEnabled")
        } else {
            self.artifactDiscoveryEnabled = false
        }
        self.artifactDiscoveryRegisteredRootsJSON = persistence.string(forKey: "artifactDiscoveryRegisteredRootsJSON", defaultValue: "[]")
        self.artifactDiscoveryAdditionalKnownPatternsJSON = persistence.string(forKey: "artifactDiscoveryAdditionalKnownPatternsJSON", defaultValue: "[]")
    }

    static func decodeJSONStringArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func encodeJSONStringArray(_ values: [String]) -> String {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(normalized),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
