import XCTest
@testable import OpenBurnBarMobile

@MainActor
final class SelfHostedQuotaRunnerStoreTests: XCTestCase {
    func testSaveStoresURLInDefaultsAndSecretOnlyInSecretStore() throws {
        let defaults = makeDefaults()
        let secrets = FakeRunnerSecrets()
        let store = SelfHostedQuotaRunnerStore(defaults: defaults, secrets: secrets)

        try store.save(
            accountID: "codex_default",
            runnerURL: " https://quota.example.com/base ",
            accessSecret: " runner-secret "
        )

        XCTAssertEqual(
            defaults.string(forKey: "selfHostedQuotaRunnerURL.codex_default"),
            "https://quota.example.com/base"
        )
        XCTAssertEqual(secrets.savedByAccount["codex_default"], "runner-secret")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("runner-secret")
        })
    }

    func testSaveDoesNotPersistURLWhenSecretStoreFails() throws {
        let defaults = makeDefaults()
        let secrets = FakeRunnerSecrets()
        secrets.error = SelfHostedQuotaRunnerError.keychain(errSecIO)
        let store = SelfHostedQuotaRunnerStore(defaults: defaults, secrets: secrets)

        XCTAssertThrowsError(
            try store.save(
                accountID: "codex_default",
                runnerURL: "https://quota.example.com",
                accessSecret: "runner-secret"
            )
        )
        XCTAssertNil(defaults.string(forKey: "selfHostedQuotaRunnerURL.codex_default"))
    }

    func testEmptySecretDeletesExistingSecretAndKeepsRunnerURL() throws {
        let defaults = makeDefaults()
        let secrets = FakeRunnerSecrets()
        secrets.savedByAccount["codex_default"] = "old-secret"
        let store = SelfHostedQuotaRunnerStore(defaults: defaults, secrets: secrets)

        try store.save(
            accountID: "codex_default",
            runnerURL: "http://localhost:8787",
            accessSecret: "   "
        )

        XCTAssertEqual(defaults.string(forKey: "selfHostedQuotaRunnerURL.codex_default"), "http://localhost:8787")
        XCTAssertNil(secrets.savedByAccount["codex_default"])
        XCTAssertEqual(secrets.deletedAccounts, ["codex_default"])
    }

    func testDeleteRemovesURLAndBestEffortDeletesSecret() throws {
        let defaults = makeDefaults()
        let secrets = FakeRunnerSecrets()
        let store = SelfHostedQuotaRunnerStore(defaults: defaults, secrets: secrets)
        try store.save(
            accountID: "codex_default",
            runnerURL: "https://quota.example.com",
            accessSecret: "runner-secret"
        )

        store.delete(accountID: "codex_default")

        XCTAssertNil(defaults.string(forKey: "selfHostedQuotaRunnerURL.codex_default"))
        XCTAssertNil(secrets.savedByAccount["codex_default"])
    }

    func testValidatedRunnerURLAllowsHttpsAndLocalhostHTTPOnly() {
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("https://quota.example.com"))
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://localhost:8787"))
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://127.0.0.1:8787"))

        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://quota.example.com"))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("ftp://quota.example.com"))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("not a url"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SelfHostedQuotaRunnerStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class FakeRunnerSecrets: SelfHostedQuotaRunnerSecretStoring {
    var savedByAccount: [String: String] = [:]
    var deletedAccounts: [String] = []
    var error: Error?

    func save(_ value: String, accountID: String) throws {
        if let error { throw error }
        savedByAccount[accountID] = value
    }

    func load(accountID: String) throws -> String? {
        if let error { throw error }
        return savedByAccount[accountID]
    }

    func delete(accountID: String) throws {
        if let error { throw error }
        deletedAccounts.append(accountID)
        savedByAccount.removeValue(forKey: accountID)
    }
}
