import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class MobileProviderWizardModelTests: XCTestCase {

    private func makeModel(
        preselectedProvider: AgentProvider? = nil,
        connectionStore: FakeProviderConnectionStore? = nil,
        subscriptionStore: FakeHostedQuotaSubscriptionStore? = nil,
        runnerSaver: FakeSelfHostedRunnerSaver? = nil
    ) -> MobileProviderWizardModel {
        MobileProviderWizardModel(
            preselectedProvider: preselectedProvider,
            onConnected: { _ in },
            onCancel: {},
            connectionStore: connectionStore ?? FakeProviderConnectionStore(),
            subscriptionStore: subscriptionStore ?? FakeHostedQuotaSubscriptionStore(),
            runnerSaver: runnerSaver ?? FakeSelfHostedRunnerSaver(),
            haptics: NoopHaptics()
        )
    }

    private func makeAccount(provider: AgentProvider, id: String = "acct_1") -> ProviderAccountDoc {
        ProviderAccountDoc(
            id: id,
            providerID: provider.providerID,
            label: "Test \(provider.displayName)",
            status: .connected,
            credentialKind: .token,
            storageScope: .cloudRefreshable,
            redactedLabel: "Test",
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - Init / first step

    func test_initWithoutProvider_startsAtPickProvider() {
        let model = makeModel()
        XCTAssertEqual(model.step, .pickProvider)
        XCTAssertNil(model.selectedProvider)
    }

    func test_initWithSingleMethodProvider_startsAtCredential() {
        // Factory has a single auth method and no remote-runner support
        let model = makeModel(preselectedProvider: .factory)
        XCTAssertEqual(model.step, .credential)
        XCTAssertEqual(model.selectedProvider, .factory)
    }

    func test_initWithMultiMethodProvider_startsAtAuthMethod() {
        let model = makeModel(preselectedProvider: .minimax)
        XCTAssertEqual(model.step, .authMethod)
    }

    func test_firstInteractiveStep_matchesNextStepAfterPicker() {
        for provider in AgentProvider.allCases {
            let staticStep = MobileProviderWizardModel.firstInteractiveStep(for: provider)
            let model = makeModel()
            let dynamicStep = model.nextStepAfterPicker(for: provider)
            XCTAssertEqual(staticStep, dynamicStep,
                           "Parity violation for \(provider.displayName): static=\(staticStep), dynamic=\(dynamicStep)")
        }
    }

    // MARK: - Direction

    func test_advanceForward_setsDirectionForward() {
        let model = makeModel(preselectedProvider: .factory)
        model.step = .credential
        model.advance(to: .connecting)
        XCTAssertEqual(model.stepDirection, .forward)
    }

    func test_advanceBackward_setsDirectionBackward() {
        let model = makeModel(preselectedProvider: .factory)
        model.step = .credential
        model.advance(to: .pickProvider)
        XCTAssertEqual(model.stepDirection, .backward)
    }

    // MARK: - Hosted gate

    func test_canContinueFromSyncMode_hostedWithoutSubscription_isFalse() {
        let sub = FakeHostedQuotaSubscriptionStore()
        sub.configure(isActive: false)
        let model = makeModel(subscriptionStore: sub)
        model.syncMode = .hosted
        XCTAssertFalse(model.canContinueFromSyncMode)
    }

    func test_canContinueFromSyncMode_hostedWithSubscription_isTrue() {
        let sub = FakeHostedQuotaSubscriptionStore()
        sub.configure(isActive: true)
        let model = makeModel(subscriptionStore: sub)
        model.syncMode = .hosted
        XCTAssertTrue(model.canContinueFromSyncMode)
    }

    func test_canContinueFromSyncMode_cloud_isAlwaysTrue() {
        let model = makeModel()
        model.syncMode = .cloud
        XCTAssertTrue(model.canContinueFromSyncMode)
    }

    func test_canContinueFromSyncMode_selfHosted_isAlwaysTrue() {
        let model = makeModel()
        model.syncMode = .selfHosted
        XCTAssertTrue(model.canContinueFromSyncMode)
    }

    // MARK: - Re-entry copy

    func test_stepTitle_saysAddAnotherForReturningUser() async {
        let conn = FakeProviderConnectionStore()
        conn.accounts = [makeAccount(provider: .factory)]
        let model = makeModel(connectionStore: conn)
        model.selectedProvider = .factory
        model.step = .credential
        await model.bootstrap()
        XCTAssertEqual(model.stepTitle, "Add another Factory account")
    }

    func test_stepTitle_saysConnectForNewUser() {
        let model = makeModel()
        model.selectedProvider = .factory
        model.step = .credential
        XCTAssertEqual(model.stepTitle, "Connect Factory")
    }

    // MARK: - Search

    func test_isSearchEmptyOfResults_whenTextAndNoMatches() {
        let model = makeModel()
        model.searchText = "zzzzz_nonexistent"
        XCTAssertTrue(model.isSearchEmptyOfResults)
    }

    func test_isSearchEmptyOfResults_falseWhenTextEmpty() {
        let model = makeModel()
        model.searchText = ""
        XCTAssertFalse(model.isSearchEmptyOfResults)
    }

    func test_matchesSearch_matchesDisplayName() {
        let model = makeModel()
        model.searchText = "openai"
        XCTAssertTrue(model.matchesSearch(.openAI))
    }

    func test_matchesSearch_matchesRegistrySummary() {
        // OpenAI registry summary: "OpenAI — proxy routing with API keys..."
        let model = makeModel()
        model.searchText = "proxy"
        XCTAssertTrue(model.matchesSearch(.openAI))
    }

    func test_matchesSearch_isCaseInsensitive() {
        let model = makeModel()
        model.searchText = "OPENAI"
        XCTAssertTrue(model.matchesSearch(.openAI))
    }

    // MARK: - Routing from picker

    func test_advanceFromPicker_multiMethod_goesToAuthMethod() {
        let model = makeModel()
        model.advanceFromPicker(to: .minimax)
        XCTAssertEqual(model.step, .authMethod)
        XCTAssertEqual(model.selectedProvider, .minimax)
    }

    func test_advanceFromPicker_singleMethodNoRemote_goesToCredential() {
        let model = makeModel()
        model.advanceFromPicker(to: .factory)
        XCTAssertEqual(model.step, .credential)
    }

    // MARK: - Back navigation

    func test_backFromSyncMode_multiMethod_goesToAuthMethod() {
        let model = makeModel(preselectedProvider: .minimax)
        model.step = .syncMode
        model.selectedProvider = .minimax
        model.backFromSyncMode()
        XCTAssertEqual(model.step, .authMethod)
    }

    func test_backFromSyncMode_singleMethod_goesToPickProvider() {
        let model = makeModel()
        model.selectedProvider = .factory
        model.step = .syncMode
        model.backFromSyncMode()
        XCTAssertEqual(model.step, .pickProvider)
    }

    func test_backFromCredential_remoteProvider_goesToSyncMode() {
        let model = makeModel()
        model.selectedProvider = .codex
        model.step = .credential
        model.backFromCredential()
        XCTAssertEqual(model.step, .syncMode)
    }

    func test_backFromCredential_multiMethodNoRemote_goesToAuthMethod() {
        let model = makeModel()
        model.selectedProvider = .minimax
        model.step = .credential
        model.backFromCredential()
        XCTAssertEqual(model.step, .authMethod)
    }

    func test_backFromCredential_singleMethodNoRemote_goesToPickProvider() {
        let model = makeModel()
        model.selectedProvider = .factory
        model.step = .credential
        model.backFromCredential()
        XCTAssertEqual(model.step, .pickProvider)
    }

    // MARK: - Cancel

    func test_handleCancel_cancelsConnectTask() {
        let model = makeModel()
        let task = Task {}
        model.connectTask = task
        model.handleCancel()
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(model.connectTask)
    }

    func test_cancelConnectingFromUser_setsNotConnectingAndAdvances() {
        let model = makeModel(preselectedProvider: .factory)
        model.step = .connecting
        model.isConnecting = true
        model.cancelConnectingFromUser()
        XCTAssertFalse(model.isConnecting)
        XCTAssertEqual(model.step, .credential)
    }

    // MARK: - Connect (cloud success)

    func test_connect_cloudSuccess_advancesToConnected() async {
        let conn = FakeProviderConnectionStore()
        let account = makeAccount(provider: .factory)
        conn.configure(connectResult: account)
        let model = makeModel(preselectedProvider: .factory, connectionStore: conn)
        model.credential = String(repeating: "a", count: 24)
        model.startConnect()
        await model.connectTask?.value
        XCTAssertEqual(model.step, .connected)
        XCTAssertEqual(model.connectedAccount?.id, account.id)
    }

    // MARK: - Connect (cloud nil → failed)

    func test_connect_cloudNil_advancesToFailed() async {
        let conn = FakeProviderConnectionStore()
        conn.configure(connectResult: nil)
        conn.error = "Bad key"
        let model = makeModel(preselectedProvider: .factory, connectionStore: conn)
        model.credential = String(repeating: "a", count: 24)
        model.startConnect()
        await model.connectTask?.value
        XCTAssertEqual(model.step, .failed)
        XCTAssertEqual(model.errorMessage, "Bad key")
    }

    // MARK: - Connect (hosted refresh throws)

    func test_connect_hostedRefreshThrows_advancesToFailed() async {
        let sub = FakeHostedQuotaSubscriptionStore()
        sub.configure(isActive: true)
        sub.configureRefreshError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refresh failed"]))
        // Codex supports hosted sync
        let model = makeModel(preselectedProvider: .codex, subscriptionStore: sub)
        model.credential = String(repeating: "a", count: 24)
        model.syncMode = .hosted
        model.startConnect()
        await model.connectTask?.value
        XCTAssertEqual(model.step, .failed)
        XCTAssertEqual(model.errorMessage, "Refresh failed")
    }

    // MARK: - Connect (hosted subscription not active)

    func test_connect_hostedNotActive_doesNotProceed() async {
        // canConnect requires subscriptionStore.isActive for hosted, so connect()
        // bails out early at the canConnect guard. This is the desired behavior:
        // the user cannot reach this state because the syncMode Continue button
        // is gated by canContinueFromSyncMode in the UI.
        let sub = FakeHostedQuotaSubscriptionStore()
        sub.configure(isActive: false)
        let model = makeModel(preselectedProvider: .codex, subscriptionStore: sub)
        model.credential = String(repeating: "a", count: 24)
        model.syncMode = .hosted
        XCTAssertFalse(model.canConnect, "Hosted without subscription should fail canConnect gate")
    }

    // MARK: - Connect (self-hosted save failure rolls back)

    func test_connect_selfHostedSaveFailure_rollsBack() async {
        let conn = FakeProviderConnectionStore()
        let account = makeAccount(provider: .codex)
        conn.configure(connectResult: account)
        let saver = FakeSelfHostedRunnerSaver()
        saver.configureSaveError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Write failed"]))
        let model = makeModel(preselectedProvider: .codex, connectionStore: conn, runnerSaver: saver)
        model.credential = "unused"
        model.syncMode = .selfHosted
        model.runnerURL = "https://runner.example.com"
        model.startConnect()
        await model.connectTask?.value
        XCTAssertEqual(model.step, .failed)
        XCTAssertEqual(model.errorMessage, "Write failed")
        XCTAssertTrue(conn.deleteCalls.count == 1, "Account should be deleted after runner save failure")
        XCTAssertTrue(saver.deleteCalls.count == 1, "Runner should be deleted after save failure")
    }

    // MARK: - Credential kind resolution

    func test_resolvedCredentialKind_apiKey_isToken() {
        // OpenAI has a registry descriptor whose primary method is .apiKey
        let model = makeModel(preselectedProvider: .openAI)
        model.selectedAuthMethodID = ProviderSetupGuide.registryDescriptor(for: .openAI)?.primaryMethod.id
        XCTAssertEqual(model.resolvedCredentialKind, .token)
    }

    func test_resolvedCredentialKind_noProvider_isToken() {
        let model = makeModel()
        XCTAssertEqual(model.resolvedCredentialKind, .token)
    }

    // MARK: - canConnect

    func test_canConnect_cloudShortCredential_isFalse() {
        let model = makeModel(preselectedProvider: .factory)
        model.credential = "short"
        XCTAssertFalse(model.canConnect)
    }

    func test_canConnect_cloudLongCredential_isTrue() {
        let model = makeModel(preselectedProvider: .factory)
        model.credential = String(repeating: "a", count: 24)
        XCTAssertTrue(model.canConnect)
    }

    func test_canConnect_hostedWithoutSubscription_isFalse() {
        let sub = FakeHostedQuotaSubscriptionStore()
        sub.configure(isActive: false)
        let model = makeModel(preselectedProvider: .codex, subscriptionStore: sub)
        model.credential = String(repeating: "a", count: 24)
        model.syncMode = .hosted
        XCTAssertFalse(model.canConnect)
    }

    func test_canConnect_selfHostedInvalidURL_isFalse() {
        let model = makeModel(preselectedProvider: .codex)
        model.syncMode = .selfHosted
        model.runnerURL = "not-a-url"
        XCTAssertFalse(model.canConnect)
    }

    func test_canConnect_selfHostedValidURL_isTrue() {
        let model = makeModel(preselectedProvider: .codex)
        model.syncMode = .selfHosted
        model.runnerURL = "https://runner.example.com"
        XCTAssertTrue(model.canConnect)
    }

    // MARK: - Default sync mode

    func test_defaultSyncMode_hostedProvider_returnsHosted() async {
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: .codex)
        let mode = await MobileProviderWizardModel.defaultSyncMode(for: guide)
        XCTAssertEqual(mode, .hosted)
    }

    func test_defaultSyncMode_noRemote_returnsCloud() async {
        let guide = ProviderSetupGuide.registryEnrichedGuide(for: .openAI)
        let mode = await MobileProviderWizardModel.defaultSyncMode(for: guide)
        XCTAssertEqual(mode, .cloud)
    }
}

// MARK: - Noop Haptics

private final class NoopHaptics: HapticPerforming {
    func selection() {}
    func light() {}
    func medium() {}
    func success() {}
    func error() {}
}
