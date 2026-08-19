import Foundation
import GRDB
import XCTest
@testable import OpenBurnBar

// MARK: - Activation Checklist Model Tests

@MainActor
final class ActivationChecklistModelTests: XCTestCase {

    // MARK: - Test Isolation

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.openburnbar.tests.activation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Factory Methods

    private func makeSettingsManager(defaults: UserDefaults) -> SettingsManager {
        SettingsManager(
            defaults: defaults,
            controllerRuntimeSecrets: KeychainStore(
                service: "tests.controller.\(UUID().uuidString)",
                legacyServices: [],
                backend: SettingsManagerTestKeychainBackend()
            ),
            chatGatewaySecrets: KeychainStore(
                service: "tests.gateway.\(UUID().uuidString)",
                legacyServices: [],
                backend: SettingsManagerTestKeychainBackend()
            ),
            launchAgentGatewayAuthTokenReader: { nil },
            // Synchronous writes so persistence assertions never race the
            // production 100 ms debounce.
            flushDelayNanoseconds: 0
        )
    }

    private func makeDataStore() throws -> DataStoreCoordinator {
        try XCTUnwrap(try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), refreshOnInit: false))
    }

    private func makeModel(
        settings: SettingsManager,
        dataStore: DataStoreCoordinator,
        inboxEnabled: Bool? = nil
    ) -> ActivationChecklistModel {
        ActivationChecklistModel(
            settingsManager: settings,
            dataStore: dataStore,
            inboxEnabledProbe: { inboxEnabled }
        )
    }

    // MARK: - Step Derivation

    func test_freshInstall_allStepsIncomplete_inOrder() throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let model = makeModel(settings: settings, dataStore: try makeDataStore())

        XCTAssertEqual(
            model.steps.map(\.id),
            [.seeNumber, .indexSessions, .turnOnMemory, .routeDrains, .armInbox],
            "The five switches must appear in the earned order the plan specifies."
        )
        XCTAssertTrue(model.steps.allSatisfy { !$0.isDone }, "A fresh install has every gate off.")
        XCTAssertEqual(model.doneCount, 0)
        XCTAssertTrue(model.shouldShowCard)
    }

    func test_seeNumberStep_completesFromTrackedSessions() throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let dataStore = try makeDataStore()
        let model = makeModel(settings: settings, dataStore: dataStore)

        XCTAssertFalse(try XCTUnwrap(model.steps.first { $0.id == .seeNumber }).isDone)

        dataStore.usageViewModel.replaceUsages(ViewTestFixtures.makeWeekOfUsages())

        XCTAssertTrue(
            try XCTUnwrap(model.steps.first { $0.id == .seeNumber }).isDone,
            "Any tracked session means the user has a real number — the step is earned, not clicked."
        )
    }

    func test_indexAndGatewaySteps_deriveFromSettingsToggles() throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let model = makeModel(settings: settings, dataStore: try makeDataStore())

        settings.conversationIndexingEnabled = true
        XCTAssertTrue(try XCTUnwrap(model.steps.first { $0.id == .indexSessions }).isDone)

        settings.gatewayEnabled = true
        XCTAssertTrue(try XCTUnwrap(model.steps.first { $0.id == .routeDrains }).isDone)

        // Live derivation cuts both ways: flipping a switch off reopens the step.
        settings.gatewayEnabled = false
        XCTAssertFalse(try XCTUnwrap(model.steps.first { $0.id == .routeDrains }).isDone)
    }

    func test_memoryStep_requiresConsent_notJustTheToggle() throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let model = makeModel(settings: settings, dataStore: try makeDataStore())

        // The user toggle defaults ON, but the G0 consent lever defaults OFF —
        // so the step must read incomplete and its action must be the consent
        // sheet, never a dead Settings toggle.
        XCTAssertTrue(settings.memoryAutomaticExtraction)
        let before = try XCTUnwrap(model.steps.first { $0.id == .turnOnMemory })
        XCTAssertFalse(before.isDone)
        XCTAssertEqual(before.action, .presentMemoryConsent)

        model.recordMemoryConsent(granted: true)

        let after = try XCTUnwrap(model.steps.first { $0.id == .turnOnMemory })
        XCTAssertTrue(after.isDone, "Consent + default-on toggle + default-on fleet gate = extraction enabled.")
        XCTAssertTrue(settings.memoryConsentShown)
    }

    func test_memoryStep_decliningConsent_marksShownButStaysDormant() throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let model = makeModel(settings: settings, dataStore: try makeDataStore())

        model.recordMemoryConsent(granted: false)

        XCTAssertFalse(settings.memoryConsentGranted)
        XCTAssertTrue(settings.memoryConsentShown)
        XCTAssertFalse(try XCTUnwrap(model.steps.first { $0.id == .turnOnMemory }).isDone)
    }

    func test_memoryStep_actionRoutesToSettings_onceConsentGranted() throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let model = makeModel(settings: settings, dataStore: try makeDataStore())

        settings.memoryConsentGranted = true
        settings.memoryAutomaticExtraction = false

        let step = try XCTUnwrap(model.steps.first { $0.id == .turnOnMemory })
        XCTAssertFalse(step.isDone)
        XCTAssertEqual(
            step.action,
            .openSettingsItem(SettingsAnchor.indexingToggle),
            "With consent granted, the remaining lever lives on the indexing/memory Settings surface."
        )
    }

    func test_inboxStep_derivesFromDaemonProbe_andUnknownCountsAsNotArmed() async throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let dataStore = try makeDataStore()

        let armed = makeModel(settings: settings, dataStore: dataStore, inboxEnabled: true)
        await armed.refreshInboxEnabled()
        XCTAssertTrue(try XCTUnwrap(armed.steps.first { $0.id == .armInbox }).isDone)

        let unreachable = makeModel(settings: settings, dataStore: dataStore, inboxEnabled: nil)
        await unreachable.refreshInboxEnabled()
        XCTAssertFalse(
            try XCTUnwrap(unreachable.steps.first { $0.id == .armInbox }).isDone,
            "An unreachable daemon must honestly read as not armed, never as done."
        )
    }

    // MARK: - Current Step

    func test_firstIncompleteStep_isCurrent_andOnlyThatOne() throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let dataStore = try makeDataStore()
        let model = makeModel(settings: settings, dataStore: dataStore)

        XCTAssertEqual(model.steps.filter(\.isCurrent).map(\.id), [.seeNumber])

        dataStore.usageViewModel.replaceUsages(ViewTestFixtures.makeWeekOfUsages())
        XCTAssertEqual(model.steps.filter(\.isCurrent).map(\.id), [.indexSessions])

        // Completing a LATER step out of order never steals "current" from the
        // first incomplete one.
        settings.gatewayEnabled = true
        XCTAssertEqual(model.steps.filter(\.isCurrent).map(\.id), [.indexSessions])

        settings.conversationIndexingEnabled = true
        XCTAssertEqual(model.steps.filter(\.isCurrent).map(\.id), [.turnOnMemory])
    }

    // MARK: - Dismissal

    func test_dismissal_persistsAcrossModelInstances() throws {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        let dataStore = try makeDataStore()
        let model = makeModel(settings: settings, dataStore: dataStore)

        XCTAssertTrue(model.shouldShowCard)
        model.dismiss()
        XCTAssertFalse(model.shouldShowCard)
        XCTAssertTrue(defaults.bool(forKey: "activationChecklistDismissed"))

        // A fresh manager over the same defaults (a relaunch) stays dismissed.
        let relaunched = makeModel(settings: makeSettingsManager(defaults: defaults), dataStore: dataStore)
        XCTAssertFalse(relaunched.shouldShowCard)
    }

    // MARK: - Self-Retire on Completion

    func test_completion_stampsTimestamp_showsOneBeat_thenRetiresForever() async throws {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        let dataStore = try makeDataStore()
        dataStore.usageViewModel.replaceUsages(ViewTestFixtures.makeWeekOfUsages())
        settings.conversationIndexingEnabled = true
        settings.memoryConsentGranted = true
        settings.gatewayEnabled = true

        let model = makeModel(settings: settings, dataStore: dataStore, inboxEnabled: true)
        XCTAssertNil(settings.activationChecklistCompletedAt)

        // The inbox probe completes the fifth step; the model stamps and beats.
        await model.refreshInboxEnabled()

        XCTAssertTrue(model.allStepsDone)
        XCTAssertNotNil(settings.activationChecklistCompletedAt)
        XCTAssertTrue(model.isShowingCompletionBeat)
        XCTAssertTrue(model.shouldShowCard, "The card lingers exactly long enough for the quiet beat.")

        model.finishCompletionBeat()
        XCTAssertFalse(model.shouldShowCard)

        // A relaunch never shows the card — or the beat — again.
        let relaunched = makeModel(
            settings: makeSettingsManager(defaults: defaults),
            dataStore: dataStore,
            inboxEnabled: true
        )
        XCTAssertFalse(relaunched.shouldShowCard)
        XCTAssertFalse(relaunched.isShowingCompletionBeat)
    }

    func test_markCompletedIfNeeded_isIdempotent_andRefusesWhileIncomplete() throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let dataStore = try makeDataStore()
        let model = makeModel(settings: settings, dataStore: dataStore)

        model.markCompletedIfNeeded()
        XCTAssertNil(settings.activationChecklistCompletedAt, "Completion is earned, never stamped early.")

        dataStore.usageViewModel.replaceUsages(ViewTestFixtures.makeWeekOfUsages())
        settings.conversationIndexingEnabled = true
        settings.memoryConsentGranted = true
        settings.gatewayEnabled = true
        // No probe injected result yet — the fifth switch is still unknown.
        model.markCompletedIfNeeded()
        XCTAssertNil(settings.activationChecklistCompletedAt)
    }
}
