import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class FakeProviderConnectionStore: ProviderConnectionProviding {
    var accounts: [ProviderAccountDoc] = []
    var error: String?

    private var _connectResult: ProviderAccountDoc?
    private var _connectHostedResult: ProviderAccountDoc?
    private var _connectSelfHostedResult: ProviderAccountDoc?
    private var _shouldThrow = false

    struct ConnectCall {
        let providerID: ProviderID
        let credential: String
        let kind: CredentialKind
        let label: String?
    }
    var connectCalls: [ConnectCall] = []

    struct DeleteCall { let account: ProviderAccountDoc }
    var deleteCalls: [DeleteCall] = []

    func configure(connectResult: ProviderAccountDoc?) {
        _connectResult = connectResult
        _connectHostedResult = connectResult
        _connectSelfHostedResult = connectResult
    }

    func load() async {}

    func connect(providerID: ProviderID, credential: String, kind: CredentialKind, label: String?) async -> ProviderAccountDoc? {
        connectCalls.append(ConnectCall(providerID: providerID, credential: credential, kind: kind, label: label))
        return _connectResult
    }

    func connectHosted(providerID: ProviderID, credential: String, kind: CredentialKind, label: String?) async -> ProviderAccountDoc? {
        connectCalls.append(ConnectCall(providerID: providerID, credential: credential, kind: kind, label: label))
        return _connectHostedResult
    }

    func connectSelfHosted(providerID: ProviderID, label: String?) async -> ProviderAccountDoc? {
        connectCalls.append(ConnectCall(providerID: providerID, credential: "", kind: .token, label: label))
        return _connectSelfHostedResult
    }

    func delete(account: ProviderAccountDoc) async {
        deleteCalls.append(DeleteCall(account: account))
    }
}
