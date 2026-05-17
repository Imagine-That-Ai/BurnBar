import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarModelVariantConfigStoreTests: XCTestCase {

    func testSeedDefaultModelVariantsCreatesOpusAndCodexVariants() async throws {
        let harness = try makeHarness(name: "variant-seed")
        let marker = harness.rootURL.appendingPathComponent("model-variants-seed.v1")

        try await harness.configStore.seedDefaultModelVariantsIfNeeded(markerURL: marker)

        let snapshot = try await harness.configStore.snapshot()
        let anthropic = snapshot.providerSettings(id: "anthropic")
        let openai = snapshot.providerSettings(id: "openai")

        let opusVariantIDs = Set(anthropic?.variants(forBaseModelID: "claude-opus-4-7").map(\.variantID) ?? [])
        XCTAssertTrue(opusVariantIDs.contains("claude-opus-4-7-high"))
        XCTAssertTrue(opusVariantIDs.contains("claude-opus-4-7-xhigh"))
        XCTAssertTrue(opusVariantIDs.contains("claude-opus-4-7-max"))

        let codexVariantIDs = Set(openai?.variants(forBaseModelID: "gpt-5.3-codex").map(\.variantID) ?? [])
        XCTAssertTrue(codexVariantIDs.contains("gpt-5.3-codex-low"))
        XCTAssertTrue(codexVariantIDs.contains("gpt-5.3-codex-medium"))
        XCTAssertTrue(codexVariantIDs.contains("gpt-5.3-codex-high"))
        XCTAssertTrue(codexVariantIDs.contains("gpt-5.3-codex-xhigh"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSeedDefaultModelVariantsIsIdempotent() async throws {
        let harness = try makeHarness(name: "variant-seed-idempotent")
        let marker = harness.rootURL.appendingPathComponent("model-variants-seed.v1")
        try await harness.configStore.seedDefaultModelVariantsIfNeeded(markerURL: marker)
        let firstSnapshot = try await harness.configStore.snapshot()
        let firstCount = (firstSnapshot.providerSettings(id: "anthropic")?.modelVariants.count ?? 0)
            + (firstSnapshot.providerSettings(id: "openai")?.modelVariants.count ?? 0)

        try await harness.configStore.seedDefaultModelVariantsIfNeeded(markerURL: marker)
        let secondSnapshot = try await harness.configStore.snapshot()
        let secondCount = (secondSnapshot.providerSettings(id: "anthropic")?.modelVariants.count ?? 0)
            + (secondSnapshot.providerSettings(id: "openai")?.modelVariants.count ?? 0)
        XCTAssertEqual(firstCount, secondCount, "Seeding must be idempotent once the marker is on disk.")
    }

    func testUpsertModelVariantRejectsUnsupportedBaseModel() async throws {
        let harness = try makeHarness(name: "variant-validation")
        let variant = BurnBarModelVariant(
            variantID: "totally-fake-high",
            label: "High",
            baseModelID: "totally-fake-model",
            thinkingLevel: .high
        )
        do {
            _ = try await harness.configStore.upsertModelVariant(providerID: "anthropic", variant: variant)
            XCTFail("Expected an unsupported model error")
        } catch let error as BurnBarConfigStoreError {
            guard case .unsupportedModel(let providerID, let modelID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "anthropic")
            XCTAssertEqual(modelID, "totally-fake-model")
        }
    }

    func testUpsertModelVariantPersistsAcrossSnapshots() async throws {
        let harness = try makeHarness(name: "variant-persist")
        let variant = BurnBarModelVariant(
            variantID: "claude-opus-4-7-high",
            label: "High",
            baseModelID: "claude-opus-4-7",
            thinkingLevel: .high
        )
        _ = try await harness.configStore.upsertModelVariant(providerID: "anthropic", variant: variant)

        let snapshot = try await harness.configStore.snapshot()
        let variants = snapshot.providerSettings(id: "anthropic")?.modelVariants ?? []
        XCTAssertTrue(variants.contains(where: { $0.variantID == "claude-opus-4-7-high" }))

        try await harness.configStore.removeModelVariant(providerID: "anthropic", variantID: "claude-opus-4-7-high")
        let after = try await harness.configStore.snapshot()
        let remaining = after.providerSettings(id: "anthropic")?.modelVariants ?? []
        XCTAssertFalse(remaining.contains(where: { $0.variantID == "claude-opus-4-7-high" }))
    }

    private struct VariantHarness {
        let rootURL: URL
        let configStore: BurnBarConfigStore
    }

    private func makeHarness(name: String) throws -> VariantHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-variant-config-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "variant-config-store-tests")
        )
        return VariantHarness(rootURL: rootURL, configStore: configStore)
    }
}
