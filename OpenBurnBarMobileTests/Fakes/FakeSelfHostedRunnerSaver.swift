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
    var onSave: (() -> Void)?

    private var _saveError: Error?
    private var _deleteError: Error?

    func configureSaveError(_ error: Error?) {
        _saveError = error
    }

    func configureDeleteError(_ error: Error?) {
        _deleteError = error
    }

    func save(accountID: String, runnerURL: String, accessSecret: String?) throws {
        if let error = _saveError { throw error }
        saveCalls.append(SaveCall(accountID: accountID, runnerURL: runnerURL, accessSecret: accessSecret))
        onSave?()
    }

    func delete(accountID: String) throws {
        if let error = _deleteError { throw error }
        deleteCalls.append(DeleteCall(accountID: accountID))
    }
}
