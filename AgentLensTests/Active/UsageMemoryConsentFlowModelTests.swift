import XCTest
@testable import OpenBurnBar

/// U2: the usage-memory consent flow model (step machine + write set).
///
/// Invariants under test:
///  - **Write split:** the model persists only the in-flow choices (placement,
///    the separate cloud-curation consent). The top-level grant/decline is
///    reported via the completion and persisted by the integrator — so a
///    completed flow alone never flips `usageMemoryConsentGranted`.
///  - **Cloud fallback:** declining the cloud step never cancels: first-run
///    falls back to `.local` and still grants; the Settings upgrade path
///    leaves the existing placement untouched.
///  - **Affirmative cloud consent:** a cloud placement is applied only after
///    the separate "Allow cloud curation" accept.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class UsageMemoryConsentFlowModelTests: XCTestCase {

    private var settingsManager: SettingsManager!

    override func setUp() {
        super.setUp()
        settingsManager = makeSettingsManager()
    }

    override func tearDown() {
        settingsManager = nil
        super.tearDown()
    }

    private func makeModel(
        mode: UsageMemoryConsentFlowModel.Mode = .firstRun,
        onCompletion: @escaping (Bool) -> Void = { _ in }
    ) -> UsageMemoryConsentFlowModel {
        UsageMemoryConsentFlowModel(
            mode: mode,
            settingsManager: settingsManager,
            onCompletion: onCompletion
        )
    }

    // MARK: - Step machine (first run)

    func testFirstRunStartsAtWhatItDoes() {
        XCTAssertEqual(makeModel().step, .whatItDoes)
    }

    func testContinueAdvancesToPlacement() {
        let model = makeModel()
        model.advanceToPlacement()
        XCTAssertEqual(model.step, .placement)
    }

    func testBackFromPlacementReturnsToWhatItDoes() {
        let model = makeModel()
        model.advanceToPlacement()
        model.goBack()
        XCTAssertEqual(model.step, .whatItDoes)
    }

    func testBackFromCloudConsentReturnsToPlacement() {
        let model = makeModel()
        model.advanceToPlacement()
        model.selectedPlacement = .cloudText
        model.confirmPlacementSelection()
        XCTAssertEqual(model.step, .cloudConsent)
        model.goBack()
        XCTAssertEqual(model.step, .placement)
    }

    // MARK: - Local grant path

    func testLocalPlacementGrantsDirectly() {
        var completions: [Bool] = []
        let model = makeModel { completions.append($0) }
        model.advanceToPlacement()
        model.selectedPlacement = .local
        model.confirmPlacementSelection()

        XCTAssertEqual(completions, [true])
        XCTAssertEqual(settingsManager.usageMemoryModelPlacement, .local)
        XCTAssertFalse(settingsManager.usageMemoryCloudCurationConsentGranted)
        // The integrator persists the top-level grant, not the model.
        XCTAssertFalse(settingsManager.usageMemoryConsentGranted)
    }

    // MARK: - Cloud grant path (separate affirmative step)

    func testCloudPlacementWithoutPriorCloudConsentRoutesToCloudStep() {
        var completions: [Bool] = []
        let model = makeModel { completions.append($0) }
        model.advanceToPlacement()
        model.selectedPlacement = .cloudText
        model.confirmPlacementSelection()

        XCTAssertEqual(model.step, .cloudConsent)
        XCTAssertTrue(completions.isEmpty)
        // No placement write until the affirmative step is answered.
        XCTAssertEqual(settingsManager.usageMemoryModelPlacement, .local)
    }

    func testAcceptCloudCurationGrantsCloudConsentAndAppliesPlacement() {
        var completions: [Bool] = []
        let model = makeModel { completions.append($0) }
        model.advanceToPlacement()
        model.selectedPlacement = .burnbarCloud
        model.confirmPlacementSelection()
        model.acceptCloudCuration()

        XCTAssertEqual(completions, [true])
        XCTAssertTrue(settingsManager.usageMemoryCloudCurationConsentGranted)
        XCTAssertEqual(settingsManager.usageMemoryModelPlacement, .burnbarCloud)
    }

    func testDecliningCloudStepFallsBackToLocalAndStillGrants() {
        var completions: [Bool] = []
        let model = makeModel { completions.append($0) }
        model.advanceToPlacement()
        model.selectedPlacement = .cloudText
        model.confirmPlacementSelection()
        model.declineCloudCuration()

        // Declining cloud is NOT a cancel: the flow grants with local placement.
        XCTAssertEqual(completions, [true])
        XCTAssertEqual(model.selectedPlacement, .local)
        XCTAssertEqual(settingsManager.usageMemoryModelPlacement, .local)
        XCTAssertFalse(settingsManager.usageMemoryCloudCurationConsentGranted)
    }

    func testCloudPlacementWithPriorCloudConsentSkipsCloudStep() {
        settingsManager.usageMemoryCloudCurationConsentGranted = true
        var completions: [Bool] = []
        let model = makeModel { completions.append($0) }
        model.advanceToPlacement()
        model.selectedPlacement = .cloudText
        model.confirmPlacementSelection()

        XCTAssertEqual(completions, [true])
        XCTAssertEqual(settingsManager.usageMemoryModelPlacement, .cloudText)
    }

    // MARK: - Decline path

    func testDeclineReportsFalseAndWritesNothing() {
        var completions: [Bool] = []
        let model = makeModel { completions.append($0) }
        model.decline()

        XCTAssertEqual(completions, [false])
        XCTAssertFalse(settingsManager.usageMemoryConsentGranted)
        XCTAssertFalse(settingsManager.usageMemoryCloudCurationConsentGranted)
        XCTAssertEqual(settingsManager.usageMemoryModelPlacement, .local)
    }

    func testCompletionFiresExactlyOnce() {
        var completions: [Bool] = []
        let model = makeModel { completions.append($0) }
        model.decline()
        model.decline()
        model.advanceToPlacement()
        model.confirmPlacementSelection()
        XCTAssertEqual(completions, [false])
    }

    // MARK: - Cloud-upgrade mode (Settings placement picker)

    func testCloudUpgradeStartsAtCloudConsentStep() {
        let model = makeModel(mode: .cloudUpgrade(.cloudText))
        XCTAssertEqual(model.step, .cloudConsent)
        XCTAssertEqual(model.selectedPlacement, .cloudText)
    }

    func testCloudUpgradeAcceptAppliesPlacementAndCloudConsent() {
        settingsManager.usageMemoryConsentGranted = true
        var completions: [Bool] = []
        let model = makeModel(mode: .cloudUpgrade(.burnbarCloud)) { completions.append($0) }
        model.acceptCloudCuration()

        XCTAssertEqual(completions, [true])
        XCTAssertTrue(settingsManager.usageMemoryCloudCurationConsentGranted)
        XCTAssertEqual(settingsManager.usageMemoryModelPlacement, .burnbarCloud)
        XCTAssertTrue(settingsManager.usageMemoryCloudCurationEnabled)
    }

    func testCloudUpgradeDeclineLeavesPlacementUntouched() {
        settingsManager.usageMemoryConsentGranted = true
        var completions: [Bool] = []
        let model = makeModel(mode: .cloudUpgrade(.cloudText)) { completions.append($0) }
        model.declineCloudCuration()

        XCTAssertEqual(completions, [true])
        XCTAssertEqual(settingsManager.usageMemoryModelPlacement, .local)
        XCTAssertFalse(settingsManager.usageMemoryCloudCurationConsentGranted)
        XCTAssertFalse(settingsManager.usageMemoryCloudCurationEnabled)
    }

    func testCloudUpgradeBackIsInert() {
        let model = makeModel(mode: .cloudUpgrade(.cloudText))
        model.goBack()
        XCTAssertEqual(model.step, .cloudConsent)
    }
}
