import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Live-catalog coverage for verbatim display-name overrides. The override is
/// the single injection point that feeds `/v1/models`, the Proxy UI, the
/// Hermes/PI apps, and Droid sync — so applying it on the base row here is what
/// makes every downstream surface inherit the rename.
final class BurnBarModelDisplayOverrideLiveCatalogTests: XCTestCase {

    func testLiveCatalogAppliesVerbatimOverrideToBaseRow() async throws {
        let harness = try makeHarness(name: "display-applies")
        _ = try await harness.configStore.setModelDisplayName(
            providerID: "anthropic",
            modelID: "claude-opus-4-7",
            displayName: "My Work Opus"
        )

        let snapshot = try await harness.liveCatalog.snapshot()
        let row = try XCTUnwrap(snapshot.models.first { $0.id == "claude-opus-4-7" })
        XCTAssertEqual(row.displayName, "My Work Opus")
        XCTAssertTrue(row.displayNameIsCustom ?? false)
        // The wire id is unchanged — routing stays on the canonical model.
        XCTAssertEqual(row.id, "claude-opus-4-7")
    }

    func testLiveCatalogClearsOverrideRestoresDefaultName() async throws {
        let harness = try makeHarness(name: "display-clears")
        _ = try await harness.configStore.setModelDisplayName(
            providerID: "anthropic",
            modelID: "claude-opus-4-7",
            displayName: "My Work Opus"
        )
        var snapshot = try await harness.liveCatalog.snapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot.models.first { $0.id == "claude-opus-4-7" }).displayNameIsCustom ?? false)

        try await harness.configStore.clearModelDisplayName(
            providerID: "anthropic",
            modelID: "claude-opus-4-7"
        )
        snapshot = try await harness.liveCatalog.snapshot()
        let row = try XCTUnwrap(snapshot.models.first { $0.id == "claude-opus-4-7" })
        XCTAssertFalse(row.displayNameIsCustom ?? true)
        XCTAssertNotEqual(row.displayName, "My Work Opus")
    }

    private struct DisplayHarness {
        let rootURL: URL
        let configStore: BurnBarConfigStore
        let liveCatalog: BurnBarLiveModelCatalog
    }

    private func makeHarness(name: String) throws -> DisplayHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-display-live-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "display-live-catalog-tests")
        )
        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: configStore,
            session: URLSession(configuration: .ephemeral)
        )
        return DisplayHarness(rootURL: rootURL, configStore: configStore, liveCatalog: liveCatalog)
    }
}
