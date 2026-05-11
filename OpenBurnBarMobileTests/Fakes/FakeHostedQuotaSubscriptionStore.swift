import Foundation
@testable import OpenBurnBarMobile

@MainActor
final class FakeHostedQuotaSubscriptionStore: HostedQuotaSubscriptionProviding {
    var isActive = false
    var isLoading = false

    private var _refreshError: Error?

    func configure(isActive: Bool) {
        self.isActive = isActive
    }

    func configureRefreshError(_ error: Error?) {
        _refreshError = error
    }

    func load() async {}

    func refreshEntitlement() async throws {
        if let error = _refreshError { throw error }
    }
}
