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
func makeDiscoveryInMemoryStore() throws -> DataStore {
    let queue = try DatabaseQueue()
    // Wave 2.1/2.1c: no live daemon in tests — chat, snapshot, vector,
    // memory, and search writes use the local doubles (pre-cutover
    // semantics) instead of the default daemon writers. (The vector/memory
    // doubles are 2.1c-ii/iii's missing wiring: without them every such
    // write escapes to the live daemon socket and the suite is red wherever
    // a daemon runs.)
    return try DataStore(
        databaseQueue: queue,
        runMigrations: true,
        refreshOnInit: false,
        chatWriter: LocalChatHistoryWriter(dbQueue: queue),
        snapshotWriter: LocalProjectMemorySnapshotWriter(dbQueue: queue),
        vectorSnapshotWriter: LocalVectorIndexSnapshotWriter(dbQueue: queue),
        memoryAuthorityWriter: LocalMemoryAuthorityWriter(dbQueue: queue),
        searchIndexWriter: LocalSearchIndexWriter(dbQueue: queue)
    )
}

func writeDiscoveryFixture(_ text: String, to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    guard let data = text.data(using: .utf8) else {
        throw NSError(domain: "AgentLensTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"])
    }
    try data.write(to: url)
}
