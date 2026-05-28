import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarModelAliasConfigStoreTests: XCTestCase {

    func testUpsertModelAliasRejectsUnsupportedBaseModel() async throws {
        let harness = try makeHarness(name: "alias-validation")
        let alias = BurnBarModelAlias(
            aliasID: "my-fake",
            baseModelID: "totally-fake-model",
            displayName: "Fake"
        )
        do {
            _ = try await harness.configStore.upsertModelAlias(providerID: "anthropic", alias: alias)
            XCTFail("Expected an unsupported model error")
        } catch let error as BurnBarConfigStoreError {
            guard case .unsupportedModel(let providerID, let modelID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "anthropic")
            XCTAssertEqual(modelID, "totally-fake-model")
        }
    }

    func testUpsertModelAliasRejectsInvalidAliasID() async throws {
        let harness = try makeHarness(name: "alias-invalid-id")
        let alias = BurnBarModelAlias(
            aliasID: "bad alias",
            baseModelID: "claude-opus-4-7",
            displayName: "Bad"
        )
        do {
            _ = try await harness.configStore.upsertModelAlias(providerID: "anthropic", alias: alias)
            XCTFail("Expected an invalid alias id error")
        } catch let error as BurnBarConfigStoreError {
            guard case .invalidModelAliasID = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUpsertModelAliasRejectsVariantCollision() async throws {
        let harness = try makeHarness(name: "alias-variant-collision")
        _ = try await harness.configStore.upsertModelVariant(
            providerID: "anthropic",
            variant: BurnBarModelVariant(
                variantID: "claude-opus-4-7-high",
                label: "High",
                baseModelID: "claude-opus-4-7",
                thinkingLevel: .high
            )
        )
        do {
            _ = try await harness.configStore.upsertModelAlias(
                providerID: "anthropic",
                alias: BurnBarModelAlias(
                    aliasID: "claude-opus-4-7-high",
                    baseModelID: "claude-opus-4-7",
                    displayName: "Collision"
                )
            )
            XCTFail("Expected a variant collision error")
        } catch let error as BurnBarConfigStoreError {
            guard case .modelAliasConflictsWithVariant(let aliasID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(aliasID, "claude-opus-4-7-high")
        }
    }

    func testUpsertModelAliasRejectsCatalogCollision() async throws {
        let harness = try makeHarness(name: "alias-catalog-collision")
        do {
            _ = try await harness.configStore.upsertModelAlias(
                providerID: "anthropic",
                alias: BurnBarModelAlias(
                    aliasID: "claude-sonnet-4-6",
                    baseModelID: "claude-opus-4-7",
                    displayName: "Collision"
                )
            )
            XCTFail("Expected a catalog collision error")
        } catch let error as BurnBarConfigStoreError {
            guard case .modelAliasConflictsWithCatalogModel(let aliasID, let baseModelID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(aliasID, "claude-sonnet-4-6")
            XCTAssertEqual(baseModelID, "claude-opus-4-7")
        }
    }

    func testUpsertModelAliasAcceptsProviderSubstringInAliasID() async throws {
        let harness = try makeHarness(name: "alias-substring-id")
        _ = try await harness.configStore.upsertModelAlias(
            providerID: "anthropic",
            alias: BurnBarModelAlias(
                aliasID: "my-claude-coder",
                baseModelID: "claude-opus-4-7",
                displayName: "My Claude Coder"
            )
        )

        let snapshot = try await harness.configStore.snapshot()
        XCTAssertTrue(snapshot.providerSettings(id: "anthropic")?.modelAliases.contains(where: {
            $0.aliasID == "my-claude-coder"
        }) ?? false)
    }

    func testUpsertModelAliasPersistsAcrossSnapshots() async throws {
        let harness = try makeHarness(name: "alias-persist")
        _ = try await harness.configStore.upsertModelAlias(
            providerID: "anthropic",
            alias: BurnBarModelAlias(
                aliasID: "my-opus",
                baseModelID: "claude-opus-4-7",
                displayName: "My Opus",
                hidesBaseModel: true
            )
        )

        let snapshot = try await harness.configStore.snapshot()
        let aliases = snapshot.providerSettings(id: "anthropic")?.modelAliases ?? []
        XCTAssertTrue(aliases.contains(where: { $0.aliasID == "my-opus" }))
        XCTAssertTrue(aliases.first(where: { $0.aliasID == "my-opus" })?.hidesBaseModel ?? false)

        try await harness.configStore.removeModelAlias(providerID: "anthropic", aliasID: "my-opus")
        let after = try await harness.configStore.snapshot()
        let remaining = after.providerSettings(id: "anthropic")?.modelAliases ?? []
        XCTAssertFalse(remaining.contains(where: { $0.aliasID == "my-opus" }))
    }

    private struct AliasHarness {
        let rootURL: URL
        let configStore: BurnBarConfigStore
    }

    private func makeHarness(name: String) throws -> AliasHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-alias-config-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "alias-config-store-tests")
        )
        return AliasHarness(rootURL: rootURL, configStore: configStore)
    }
}
