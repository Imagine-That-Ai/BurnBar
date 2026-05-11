import Foundation
@testable import OpenBurnBarMobile

@MainActor
final class FakeSelfHostedRunnerSaver: SelfHostedRunnerSaving {
    struct SaveCall {
        let accountID: String
        let runnerURL: String
        let accessSecret: String?
    }
    var saveCalls: [SaveCall] = []

    struct DeleteCall { let accountID: String }
    var deleteCalls: [DeleteCall] = []

    private var _saveError: Error?

    func configureSaveError(_ error: Error?) {
        _saveError = error
    }

    func save(accountID: String, runnerURL: String, accessSecret: String?) throws {
        if let error = _saveError { throw error }
        saveCalls.append(SaveCall(accountID: accountID, runnerURL: runnerURL, accessSecret: accessSecret))
    }

    func delete(accountID: String) {
        deleteCalls.append(DeleteCall(accountID: accountID))
    }
}
