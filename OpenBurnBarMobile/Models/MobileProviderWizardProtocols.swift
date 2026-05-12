import Foundation
import OpenBurnBarCore

// MARK: - Provider Connection

@MainActor
protocol ProviderConnectionProviding: AnyObject {
    var accounts: [ProviderAccountDoc] { get }
    var error: String? { get }
    func load() async
    func connect(providerID: ProviderID, credential: String, kind: CredentialKind, label: String?) async -> ProviderAccountDoc?
    func connectHosted(providerID: ProviderID, credential: String, kind: CredentialKind, label: String?) async -> ProviderAccountDoc?
    func connectSelfHosted(providerID: ProviderID, label: String?) async -> ProviderAccountDoc?
    func delete(account: ProviderAccountDoc) async
}

// MARK: - Hosted Quota Subscription

@MainActor
protocol HostedQuotaSubscriptionProviding: AnyObject {
    var isActive: Bool { get }
    var isLoading: Bool { get }
    func load() async
    func refreshEntitlement() async throws
}

// MARK: - Self-Hosted Runner Persistence

@MainActor
protocol SelfHostedRunnerSaving: AnyObject {
    func save(accountID: String, runnerURL: String, accessSecret: String?) throws
    func delete(accountID: String)
}

// MARK: - Haptics

protocol HapticPerforming: AnyObject {
    func selection()
    func light()
    func medium()
    func success()
    func error()
}

// MARK: - Retroactive conformances

extension ProviderConnectionStore: ProviderConnectionProviding {}
extension HostedQuotaSubscriptionStore: HostedQuotaSubscriptionProviding {}
extension SelfHostedQuotaRunnerStore: SelfHostedRunnerSaving {}

final class LiveHaptics: HapticPerforming {
    func selection() { Haptics.selection() }
    func light()     { Haptics.light() }
    func medium()    { Haptics.medium() }
    func success()   { Haptics.success() }
    func error()     { Haptics.error() }
}
