import Foundation

actor CLIBridgeStreamRuntimeCoordinator {
    private var runningProcess: Process?
    private var runningProcessToken: UInt64 = 0

    private var httpStreamTask: Task<Void, Never>?
    private var activeHTTPStreamToken: UInt64 = 0
    private var nextHTTPStreamToken: UInt64 = 0

    func registerRunningProcess(_ process: Process) -> UInt64 {
        runningProcessToken += 1
        runningProcess = process
        return runningProcessToken
    }

    func clearRunningProcess(token: UInt64) {
        guard runningProcessToken == token else { return }
        runningProcess = nil
    }

    func cancelRunningProcess(token: UInt64) {
        guard runningProcessToken == token else { return }
        runningProcess?.terminate()
        runningProcess = nil
    }

    func nextHTTPStreamID() -> UInt64 {
        nextHTTPStreamToken += 1
        return nextHTTPStreamToken
    }

    func installHTTPStreamTask(_ task: Task<Void, Never>, streamID: UInt64) {
        httpStreamTask?.cancel()
        httpStreamTask = task
        activeHTTPStreamToken = streamID
    }

    func clearHTTPStreamTask(streamID: UInt64) {
        guard activeHTTPStreamToken == streamID else { return }
        httpStreamTask = nil
    }

    func cancelHTTPStreamTask(streamID: UInt64) {
        guard activeHTTPStreamToken == streamID else { return }
        httpStreamTask?.cancel()
        httpStreamTask = nil
        activeHTTPStreamToken = 0
    }

    func cancelAll() {
        runningProcess?.terminate()
        runningProcess = nil
        httpStreamTask?.cancel()
        httpStreamTask = nil
        activeHTTPStreamToken = 0
    }
}
