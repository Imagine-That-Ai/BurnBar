import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

final class AccountStoreProfileTests: XCTestCase {
    func testDeriveProfilesIncludesCurrentUserAndProviderAccounts() {
        let current = BurnBarProfile(
            id: "firebase-user",
            displayName: "Alberto",
            email: "alberto@example.com",
            photoURL: nil,
            isActive: false
        )
        let accounts = [
            providerAccount(
                id: "acct-a",
                providerID: "openai",
                label: "OpenAI Work",
                identityHint: "work@example.com",
                linkedSwitcherProfileID: "work",
                sortKey: 0
            ),
            providerAccount(
                id: "acct-b",
                providerID: "anthropic",
                label: "Claude Work",
                identityHint: "not-an-email",
                linkedSwitcherProfileID: "work",
                sortKey: 1
            ),
            providerAccount(
                id: "acct-c",
                providerID: "factory",
                label: "Factory Personal",
                identityHint: "personal@example.com",
                sortKey: 2
            ),
            providerAccount(
                id: "deleted",
                providerID: "codex",
                label: "Deleted",
                status: .deleted
            )
        ]

        let profiles = AccountStore.deriveProfiles(
            currentProfile: current,
            providerAccounts: accounts,
            activeProfileID: "provider-account:acct-c"
        )

        XCTAssertEqual(profiles.map(\.id), ["firebase-user", "switcher:work", "provider-account:acct-c"])
        XCTAssertEqual(profiles.first(where: { $0.id == "switcher:work" })?.displayName, "OpenAI Work")
        XCTAssertEqual(profiles.first(where: { $0.id == "switcher:work" })?.email, "work@example.com")
        XCTAssertNil(profiles.first(where: { $0.id == "provider-account:acct-c" })?.photoURL)
        XCTAssertEqual(profiles.first(where: { $0.isActive })?.id, "provider-account:acct-c")
    }

    func testDeriveProfilesFallsBackToCurrentUserWhenPersistedActiveProfileIsStale() {
        let current = BurnBarProfile(
            id: "firebase-user",
            displayName: "Alberto",
            email: nil,
            photoURL: nil,
            isActive: false
        )

        let profiles = AccountStore.deriveProfiles(
            currentProfile: current,
            providerAccounts: [
                providerAccount(id: "acct-a", providerID: "openai", label: "OpenAI Work")
            ],
            activeProfileID: "missing"
        )

        XCTAssertEqual(profiles.first(where: { $0.isActive })?.id, "firebase-user")
    }

    private func providerAccount(
        id: String,
        providerID: String,
        label: String,
        identityHint: String? = nil,
        linkedSwitcherProfileID: String? = nil,
        status: ProviderAccountStatus = .connected,
        sortKey: Double = 0
    ) -> ProviderAccountDoc {
        ProviderAccountDoc(
            id: id,
            providerID: ProviderID(rawValue: providerID),
            label: label,
            identityHint: identityHint,
            status: status,
            credentialKind: .token,
            storageScope: .cloudRefreshable,
            redactedLabel: "sk-...",
            linkedSwitcherProfileID: linkedSwitcherProfileID,
            sortKey: sortKey,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
