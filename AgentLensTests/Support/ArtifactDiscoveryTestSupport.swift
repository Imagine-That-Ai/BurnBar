import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class StubArtifactDiscoverySettings: ArtifactDiscoverySettingsProviding {
    var artifactDiscoveryEnabled: Bool
    var artifactDiscoveryRegisteredRoots: [String]
    var artifactDiscoveryAdditionalKnownPatterns: [String]

    init(
        artifactDiscoveryEnabled: Bool,
        artifactDiscoveryRegisteredRoots: [String],
        artifactDiscoveryAdditionalKnownPatterns: [String] = []
    ) {
        self.artifactDiscoveryEnabled = artifactDiscoveryEnabled
        self.artifactDiscoveryRegisteredRoots = artifactDiscoveryRegisteredRoots
        self.artifactDiscoveryAdditionalKnownPatterns = artifactDiscoveryAdditionalKnownPatterns
    }
}

@MainActor
func makeDiscoveryInMemoryStore() throws -> DataStoreCoordinator {
    let queue = try DatabaseQueue(path: ":memory:")
    return try DataStoreCoordinator(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
}

func writeDiscoveryFixture(_ text: String, to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    guard let data = text.data(using: .utf8) else {
        throw NSError(domain: "AgentLensTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"])
    }
    try data.write(to: url)
}
