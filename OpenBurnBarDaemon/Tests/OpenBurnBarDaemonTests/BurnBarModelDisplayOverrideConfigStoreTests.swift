import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Config-store coverage for verbatim model display-name overrides.
/// These relabel a model for humans without touching its wire id or routing,
/// so unlike aliases they do not validate against catalog collisions.
final class BurnBarModelDisplayOverrideConfigStoreTests: XCTestCase {

    func testSetDisplayNamePersistsAcrossSnapshots() async throws {
        let harness = try makeHarness(name: "display-persist")
        let override = try await harness.configStore.setModelDisplayName(
            providerID: "anthropic",
            modelID: "claude-opus-4-7",
            displayName: "My Opus"
        )
        XCTAssertEqual(override.modelID, "claude-opus-4-7")
        XCTAssertEqual(override.displayName, "My Opus")

        let snapshot = try await harness.configStore.snapshot()
        let overrides = snapshot.providerSettings(id: "anthropic")?.modelDisplayOverrides ?? []
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(snapshot.providerSettings(id: "anthropic")?.displayName(forModelID: "claude-opus-4-7"), "My Opus")
    }

    func testSetDisplayNameReplacesPriorOverride() async throws {
        let harness = try makeHarness(name: "display-replace")
        _ = try await harness.configStore.setModelDisplayName(
            providerID: "anthropic", modelID: "claude-opus-4-7", displayName: "First"
        )
        _ = try await harness.configStore.setModelDisplayName(
            providerID: "anthropic", modelID: "claude-opus-4-7", displayName: "Second"
        )
        let snapshot = try await harness.configStore.snapshot()
        let overrides = snapshot.providerSettings(id: "anthropic")?.modelDisplayOverrides ?? []
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides.first?.displayName, "Second")
    }

    func testClearDisplayNameRemovesOverride() async throws {
        let harness = try makeHarness(name: "display-clear")
        _ = try await harness.configStore.setModelDisplayName(
            providerID: "anthropic", modelID: "claude-opus-4-7", displayName: "My Opus"
        )
        try await harness.configStore.clearModelDisplayName(
            providerID: "anthropic", modelID: "claude-opus-4-7"
        )
        let snapshot = try await harness.configStore.snapshot()
        let overrides = snapshot.providerSettings(id: "anthropic")?.modelDisplayOverrides ?? []
        XCTAssertTrue(overrides.isEmpty)
    }

    func testSetDisplayNameRejectsBlankName() async throws {
        let harness = try makeHarness(name: "display-blank")
        do {
            _ = try await harness.configStore.setModelDisplayName(
                providerID: "anthropic", modelID: "claude-opus-4-7", displayName: "   "
            )
            XCTFail("Expected an invalid display name error")
        } catch let error as BurnBarConfigStoreError {
            guard case .invalidModelDisplayName(let modelID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(modelID, "claude-opus-4-7")
        }
    }

    func testSetDisplayNameAcceptsLiveOnlyModelNotInStaticCatalog() async throws {
        // Overrides are forgiving by design: renaming a model that the static
        // catalog does not know about must still persist (it applies once that
        // model is advertised live). This is the key difference vs. aliases.
        let harness = try makeHarness(name: "display-live-only")
        let override = try await harness.configStore.setModelDisplayName(
            providerID: "anthropic",
            modelID: "claude-opus-4-7-some-future-snapshot",
            displayName: "Future Opus"
        )
        XCTAssertEqual(override.displayName, "Future Opus")
        let snapshot = try await harness.configStore.snapshot()
        XCTAssertEqual(
            snapshot.providerSettings(id: "anthropic")?.displayName(forModelID: "claude-opus-4-7-some-future-snapshot"),
            "Future Opus"
        )
    }

    private struct DisplayHarness {
        let rootURL: URL
        let configStore: BurnBarConfigStore
    }

    private func makeHarness(name: String) throws -> DisplayHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-display-config-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "display-config-store-tests")
        )
        return DisplayHarness(rootURL: rootURL, configStore: configStore)
    }
}
