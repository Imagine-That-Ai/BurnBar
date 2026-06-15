import Foundation
import XCTest
import OpenBurnBarCore

// MARK: - ElderWandPreset Tests
//
// Exercises `Array<ElderWandPreset>.presetsSanitized()` and the OpenRouter
// Fusion contract constants / `isWithinContractBounds` predicate.
// No host-app dependency — only OpenBurnBarCore is imported.

final class ElderWandPresetTests: XCTestCase {

    // MARK: - Helpers

    private func makePreset(
        name: String = "Test",
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

    // MARK: - Contract constants

    func test_defaultMaxToolCalls_isEight() {
        XCTAssertEqual(ElderWandPreset.defaultMaxToolCalls, 8)
    }

    func test_maxToolCallsRange_isOneToSixteen() {
        XCTAssertEqual(ElderWandPreset.maxToolCallsRange, 1...16)
    }

    func test_analysisPanelRange_isOneToEight() {
        XCTAssertEqual(ElderWandPreset.analysisPanelRange, 1...8)
    }

    // MARK: - isWithinContractBounds

    func test_isWithinContractBounds_validPreset() {
        let preset = makePreset(
            analysisModelIDs: ["gpt-4o", "claude-opus-4"],
            maxToolCalls: 8
        )
        XCTAssertTrue(preset.isWithinContractBounds)
    }

    func test_isWithinContractBounds_singleAnalysisModel() {
        let preset = makePreset(
            analysisModelIDs: ["gpt-4o"],
            maxToolCalls: 1
        )
        XCTAssertTrue(preset.isWithinContractBounds)
    }

    func test_isWithinContractBounds_maxPanelAndMaxToolCalls() {
        let preset = makePreset(
            analysisModelIDs: Array(repeating: "model", count: 8),
            maxToolCalls: 16
        )
        XCTAssertTrue(preset.isWithinContractBounds)
    }

    func test_isWithinContractBounds_emptyPanelViolatesContract() {
        let preset = makePreset(
            analysisModelIDs: [],
            maxToolCalls: 8
        )
        XCTAssertFalse(preset.isWithinContractBounds)
    }

    func test_isWithinContractBounds_oversizedPanelViolatesContract() {
        let preset = makePreset(
            analysisModelIDs: Array(repeating: "model", count: 9),
            maxToolCalls: 8
        )
        XCTAssertFalse(preset.isWithinContractBounds)
    }

    func test_isWithinContractBounds_zeroToolCallsViolatesContract() {
        let preset = makePreset(
            analysisModelIDs: ["gpt-4o"],
            maxToolCalls: 0
        )
        XCTAssertFalse(preset.isWithinContractBounds)
    }

    func test_isWithinContractBounds_excessiveToolCallsViolatesContract() {
        let preset = makePreset(
            analysisModelIDs: ["gpt-4o"],
            maxToolCalls: 17
        )
        XCTAssertFalse(preset.isWithinContractBounds)
    }

    // MARK: - presetsSanitized: empty array

    func test_presetsSanitized_emptyArray_returnsEmpty() {
        let result: [ElderWandPreset] = [].presetsSanitized()
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - presetsSanitized: zero defaults → first promoted

    func test_presetsSanitized_noDefault_promotesFirst() {
        let first = makePreset(name: "Alpha", isDefault: false)
        let second = makePreset(name: "Beta", isDefault: false)
        let result = [first, second].presetsSanitized()

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].isDefault, "First preset should be promoted to default")
        XCTAssertFalse(result[1].isDefault)
        XCTAssertEqual(result[0].name, "Alpha")
    }

    func test_presetsSanitized_noDefault_singleElement_promoted() {
        let lone = makePreset(name: "Solo", isDefault: false)
        let result = [lone].presetsSanitized()

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isDefault)
    }

    // MARK: - presetsSanitized: multiple defaults → only first kept

    func test_presetsSanitized_multipleDefaults_onlyFirstKept() {
        let first = makePreset(name: "Alpha", isDefault: true)
        let second = makePreset(name: "Beta", isDefault: true)
        let third = makePreset(name: "Gamma", isDefault: true)
        let result = [first, second, third].presetsSanitized()

        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0].isDefault, "Only the first default should remain")
        XCTAssertFalse(result[1].isDefault)
        XCTAssertFalse(result[2].isDefault)
        XCTAssertEqual(result[0].name, "Alpha")
    }

    func test_presetsSanitized_multipleDefaults_nonFirstAlsoDefault_demoted() {
        let first = makePreset(name: "Alpha", isDefault: false)
        let second = makePreset(name: "Beta", isDefault: true)
        let third = makePreset(name: "Gamma", isDefault: true)
        let result = [first, second, third].presetsSanitized()

        XCTAssertEqual(result.count, 3)
        // "Beta" is the first element with isDefault==true; "Alpha" had no flag.
        // presetsSanitized: multiple-default branch: first *marked* default wins.
        XCTAssertFalse(result[0].isDefault)
        XCTAssertTrue(result[1].isDefault, "Beta was first marked default")
        XCTAssertFalse(result[2].isDefault)
    }

    // MARK: - presetsSanitized: already single default → unchanged

    func test_presetsSanitized_alreadySingleDefault_returnedUnchanged() {
        let first = makePreset(name: "Alpha", isDefault: false)
        let second = makePreset(name: "Beta", isDefault: true)
        let third = makePreset(name: "Gamma", isDefault: false)
        let input = [first, second, third]
        let result = input.presetsSanitized()

        XCTAssertEqual(result.count, 3)
        XCTAssertFalse(result[0].isDefault)
        XCTAssertTrue(result[1].isDefault)
        XCTAssertFalse(result[2].isDefault)
        // Verify identity by comparing all IDs and names.
        XCTAssertEqual(result.map(\.id), input.map(\.id))
    }

    // MARK: - withIsDefault

    func test_withIsDefault_createsModifiedCopy() {
        let preset = makePreset(isDefault: false)
        let promoted = preset.withIsDefault(true)
        XCTAssertTrue(promoted.isDefault)
        XCTAssertEqual(promoted.id, preset.id)
        XCTAssertEqual(promoted.name, preset.name)
        XCTAssertEqual(promoted.analysisModelIDs, preset.analysisModelIDs)
        XCTAssertEqual(promoted.judgeModelID, preset.judgeModelID)
        XCTAssertEqual(promoted.maxToolCalls, preset.maxToolCalls)
    }

    func test_withIsDefault_false_demotesDefault() {
        let preset = makePreset(isDefault: true)
        let demoted = preset.withIsDefault(false)
        XCTAssertFalse(demoted.isDefault)
        XCTAssertEqual(demoted.id, preset.id)
    }
}
