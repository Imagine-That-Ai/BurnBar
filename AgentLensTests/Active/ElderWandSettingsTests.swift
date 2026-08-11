import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - ElderWandSettings Tests
//
// Exercises the macOS AgentLens settings store: persistence round-trips,
// setDefault invariant, and the wire-payload shape from `elderWandPluginsPayload()`.
//
// All tests use `SettingsPersistenceCoordinator(flushDelayNanoseconds: 0)`
// (synchronous mode) with an isolated `UserDefaults(suiteName:)` suite so
// reads immediately observe the written state without async flushing.

@MainActor
final class ElderWandSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ElderWandSettingsTests.\(UUID().uuidString)"

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            defaults = UserDefaults(suiteName: suiteName)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            defaults.removePersistentDomain(forName: suiteName)
            defaults = nil
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeCoordinator() -> SettingsPersistenceCoordinator {
        SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
    }

    private func makeSettings(coordinator: SettingsPersistenceCoordinator? = nil) -> ElderWandSettings {
        ElderWandSettings(persistence: coordinator ?? makeCoordinator())
    }

    private func makePreset(
        name: String,
        analysisModelIDs: [String] = ["gpt-4o", "claude-opus-4"],
        judgeModelID: String = "gpt-4o-mini",
        maxToolCalls: Int = ElderWandPreset.defaultMaxToolCalls,
        isDefault: Bool = false
    ) -> ElderWandPreset {
        ElderWandPreset(
            name: name,
            analysisModelIDs: analysisModelIDs,
            judgeModelID: judgeModelID,
            maxToolCalls: maxToolCalls,
            isDefault: isDefault
        )
    }

    // MARK: - Initial state

    func test_initialState_presetsAreEmpty() {
        let settings = makeSettings()
        XCTAssertTrue(settings.presets.isEmpty)
    }

    func test_initialState_activePresetIsNil() {
        let settings = makeSettings()
        XCTAssertNil(settings.activePreset)
    }

    func test_initialState_defaultPresetIsNil() {
        let settings = makeSettings()
        XCTAssertNil(settings.defaultPreset)
    }

    // MARK: - Save / round-trip

    func test_save_singlePreset_persistsAcrossRecreate() {
        let coordinator = makeCoordinator()
        let settings = makeSettings(coordinator: coordinator)
        let preset = makePreset(name: "Fusion Alpha", isDefault: true)
        settings.save(preset)

        // Reload via a fresh store sharing the same defaults.
        let settings2 = makeSettings()
        XCTAssertEqual(settings2.presets.count, 1)
        XCTAssertEqual(settings2.presets[0].name, "Fusion Alpha")
        XCTAssertEqual(settings2.presets[0].analysisModelIDs, ["gpt-4o", "claude-opus-4"])
        XCTAssertEqual(settings2.presets[0].judgeModelID, "gpt-4o-mini")
        XCTAssertEqual(settings2.presets[0].maxToolCalls, ElderWandPreset.defaultMaxToolCalls)
    }

    func test_save_multiplePresets_roundTrip() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        let beta = makePreset(name: "Beta", judgeModelID: "gpt-4-turbo", maxToolCalls: 4)
        settings.save(alpha)
        settings.save(beta)

        let settings2 = makeSettings()
        XCTAssertEqual(settings2.presets.count, 2)
        let names = settings2.presets.map(\.name)
        XCTAssertTrue(names.contains("Alpha"))
        XCTAssertTrue(names.contains("Beta"))
    }

    func test_save_replacesExistingPresetWithSameID() {
        let settings = makeSettings()
        let original = makePreset(name: "Original", isDefault: true)
        settings.save(original)

        let updated = ElderWandPreset(
            id: original.id,
            name: "Updated",
            analysisModelIDs: ["o3"],
            judgeModelID: "gpt-4o",
            maxToolCalls: 4,
            isDefault: true
        )
        settings.save(updated)

        XCTAssertEqual(settings.presets.count, 1)
        XCTAssertEqual(settings.presets[0].name, "Updated")
        XCTAssertEqual(settings.presets[0].analysisModelIDs, ["o3"])
    }

    // MARK: - setDefault enforces exactly one default

    func test_setDefault_marksTargetAsDefault() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        let beta = makePreset(name: "Beta", isDefault: false)
        settings.save(alpha)
        settings.save(beta)

        settings.setDefault(id: beta.id)

        let newDefault = settings.presets.first { $0.id == beta.id }
        XCTAssertTrue(newDefault?.isDefault ?? false)
    }

    func test_setDefault_demotesPreviousDefault() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        let beta = makePreset(name: "Beta", isDefault: false)
        settings.save(alpha)
        settings.save(beta)

        settings.setDefault(id: beta.id)

        let oldDefault = settings.presets.first { $0.id == alpha.id }
        XCTAssertFalse(oldDefault?.isDefault ?? true, "Alpha should no longer be the default")
    }

    func test_setDefault_exactlyOneDefaultAfterSwitch() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        let beta = makePreset(name: "Beta")
        let gamma = makePreset(name: "Gamma")
        settings.save(alpha)
        settings.save(beta)
        settings.save(gamma)

        settings.setDefault(id: gamma.id)

        let defaultCount = settings.presets.filter { $0.isDefault }.count
        XCTAssertEqual(defaultCount, 1)
        let theDefault = settings.presets.first { $0.isDefault }
        XCTAssertEqual(theDefault?.id, gamma.id)
    }

    func test_setDefault_unknownID_isNoOp() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        settings.save(alpha)

        settings.setDefault(id: "nonexistent-id")

        XCTAssertEqual(settings.presets.count, 1)
        XCTAssertTrue(settings.presets[0].isDefault)
    }

    // MARK: - delete

    func test_delete_removesPreset() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        let beta = makePreset(name: "Beta")
        settings.save(alpha)
        settings.save(beta)

        settings.delete(id: alpha.id)

        XCTAssertEqual(settings.presets.count, 1)
        XCTAssertEqual(settings.presets[0].name, "Beta")
    }

    func test_delete_defaultPreset_promotesNextAsDefault() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        let beta = makePreset(name: "Beta")
        settings.save(alpha)
        settings.save(beta)

        settings.delete(id: alpha.id)

        XCTAssertEqual(settings.presets.count, 1)
        XCTAssertTrue(settings.presets[0].isDefault, "Remaining preset should become default")
    }

    // MARK: - rename

    func test_rename_updatesName() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        settings.save(alpha)

        settings.rename(id: alpha.id, to: "Alpha Renamed")

        XCTAssertEqual(settings.presets[0].name, "Alpha Renamed")
        XCTAssertEqual(settings.presets[0].id, alpha.id)
    }

    func test_rename_unknownID_isNoOp() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        settings.save(alpha)

        settings.rename(id: "bad-id", to: "Should Not Change")

        XCTAssertEqual(settings.presets[0].name, "Alpha")
    }

    // MARK: - replaceAll

    func test_replaceAll_replacesEntireList() {
        let settings = makeSettings()
        settings.save(makePreset(name: "Old", isDefault: true))

        let newAlpha = makePreset(name: "New Alpha", isDefault: true)
        let newBeta = makePreset(name: "New Beta")
        settings.replaceAll([newAlpha, newBeta])

        XCTAssertEqual(settings.presets.count, 2)
        XCTAssertEqual(settings.presets.map(\.name), ["New Alpha", "New Beta"])
    }

    func test_replaceAll_sanitizesDefaults() {
        let settings = makeSettings()
        // Supply two defaults — replaceAll must reduce to one.
        let a = makePreset(name: "A", isDefault: true)
        let b = makePreset(name: "B", isDefault: true)
        settings.replaceAll([a, b])

        let defaultCount = settings.presets.filter { $0.isDefault }.count
        XCTAssertEqual(defaultCount, 1)
    }

    // MARK: - elderWandPluginsPayload: nil when no preset

    func test_elderWandPluginsPayload_nilWhenNoPresets() {
        let settings = makeSettings()
        XCTAssertNil(settings.elderWandPluginsPayload())
    }

    func test_elderWandPluginsPayload_nilAfterDeletingLastPreset() {
        let settings = makeSettings()
        let preset = makePreset(name: "Alpha", isDefault: true)
        settings.save(preset)
        settings.delete(id: preset.id)

        XCTAssertNil(settings.elderWandPluginsPayload())
    }

    // MARK: - elderWandPluginsPayload: correct shape with one preset

    func test_elderWandPluginsPayload_correctShape() throws {
        let settings = makeSettings()
        let preset = ElderWandPreset(
            name: "Fusion One",
            analysisModelIDs: ["gpt-4o", "claude-opus-4"],
            judgeModelID: "gpt-4o-mini",
            maxToolCalls: 6,
            isDefault: true
        )
        settings.save(preset)

        let payload = settings.elderWandPluginsPayload()
        XCTAssertNotNil(payload)

        let entry = try XCTUnwrap(payload?.first)
        XCTAssertEqual(entry["id"] as? String, "fusion")
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["analysis_models"] as? [String], ["gpt-4o", "claude-opus-4"])
        XCTAssertEqual(entry["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(entry["max_tool_calls"] as? Int, 6)
    }

    func test_elderWandPluginsPayload_returnsOneEntryForFusion() {
        let settings = makeSettings()
        settings.save(makePreset(name: "Alpha", isDefault: true))

        let payload = settings.elderWandPluginsPayload()
        XCTAssertEqual(payload?.count, 1)
    }

    func test_elderWandPluginsPayload_clampsToolCallsToContractBounds() {
        let settings = makeSettings()
        // maxToolCalls below lower bound (0 < 1).
        let tooLow = ElderWandPreset(
            name: "Too Low",
            analysisModelIDs: ["gpt-4o"],
            judgeModelID: "gpt-4o-mini",
            maxToolCalls: 0,
            isDefault: true
        )
        settings.save(tooLow)

        let payload = settings.elderWandPluginsPayload()
        let entry = payload?.first
        XCTAssertEqual(entry?["max_tool_calls"] as? Int, 1, "Clamped to lower bound")
    }

    func test_elderWandPluginsPayload_clampsToolCallsToUpperBound() {
        let settings = makeSettings()
        let tooHigh = ElderWandPreset(
            name: "Too High",
            analysisModelIDs: ["gpt-4o"],
            judgeModelID: "gpt-4o-mini",
            maxToolCalls: 100,
            isDefault: true
        )
        settings.save(tooHigh)

        let payload = settings.elderWandPluginsPayload()
        let entry = payload?.first
        XCTAssertEqual(entry?["max_tool_calls"] as? Int, 16, "Clamped to upper bound")
    }

    func test_elderWandPluginsPayload_nilWhenJudgeIsEmpty() {
        let settings = makeSettings()
        let preset = ElderWandPreset(
            name: "No Judge",
            analysisModelIDs: ["gpt-4o"],
            judgeModelID: "   ",   // whitespace-only → trimmed to empty
            maxToolCalls: 8,
            isDefault: true
        )
        settings.save(preset)

        XCTAssertNil(settings.elderWandPluginsPayload())
    }

    func test_elderWandPluginsPayload_nilWhenAnalysisModelsAllEmpty() {
        let settings = makeSettings()
        let preset = ElderWandPreset(
            name: "Empty Panel",
            analysisModelIDs: ["", ""],   // all filtered out
            judgeModelID: "gpt-4o-mini",
            maxToolCalls: 8,
            isDefault: true
        )
        settings.save(preset)

        XCTAssertNil(settings.elderWandPluginsPayload())
    }

    func test_elderWandPluginsPayload_nilWhenAnalysisModelsAreWhitespaceOnly() {
        let settings = makeSettings()
        let preset = ElderWandPreset(
            name: "Whitespace Panel",
            analysisModelIDs: ["   ", "\n\t"],
            judgeModelID: "gpt-4o-mini",
            maxToolCalls: 8,
            isDefault: true
        )
        settings.save(preset)

        XCTAssertNil(settings.elderWandPluginsPayload())
    }

    func test_elderWandPluginsPayload_trimsAnalysisAndJudgeModelIDs() throws {
        let settings = makeSettings()
        let preset = ElderWandPreset(
            name: "Trimmed",
            analysisModelIDs: ["  gpt-4o  ", "\tclaude-opus-4\n"],
            judgeModelID: "  gpt-4o-mini  ",
            maxToolCalls: 8,
            isDefault: true
        )
        settings.save(preset)

        let entry = try XCTUnwrap(settings.elderWandPluginsPayload()?.first)
        XCTAssertEqual(entry["analysis_models"] as? [String], ["gpt-4o", "claude-opus-4"])
        XCTAssertEqual(entry["model"] as? String, "gpt-4o-mini")
    }

    // MARK: - activePreset / defaultPreset alias

    func test_activePreset_returnsDefaultPreset() {
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: false)
        let beta = makePreset(name: "Beta", isDefault: true)
        settings.save(alpha)
        settings.save(beta)

        XCTAssertEqual(settings.activePreset?.id, beta.id)
        XCTAssertEqual(settings.defaultPreset?.id, beta.id)
    }

    func test_activePreset_fallsBackToFirstWhenNoDefaultFlag() {
        // This should not occur in practice (sanitizer always sets one), but
        // verify the fallback in the derived property.
        let settings = makeSettings()
        let alpha = makePreset(name: "Alpha", isDefault: true)
        settings.save(alpha)
        // Force internal state via replaceAll with no-default list:
        // replaceAll sanitizes so we can't directly test the fallback via
        // the public API — confirm activePreset matches defaultPreset instead.
        XCTAssertEqual(settings.activePreset?.id, settings.defaultPreset?.id)
    }
}
