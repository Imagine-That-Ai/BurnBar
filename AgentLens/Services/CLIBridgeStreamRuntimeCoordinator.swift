import Foundation

actor CLIBridgeStreamRuntimeCoordinator {
    private var runningProcess: Process?
    private var runningProcessToken: UInt64 = 0
    /// `Process.terminate()` raises an uncatchable NSInvalidArgumentException
    /// when the task was never launched. Registrations made before
    /// `process.run()` (the stream runner) pass `launched: false`; termination
    /// requests arriving in that window are deferred and reported back through
    /// `markProcessLaunched`, whose caller then terminates the just-launched
    /// process itself.
    private var runningProcessLaunched = true
    private var terminationRequestedBeforeLaunch = false

    private var httpStreamTask: Task<Void, Never>?
    private var activeHTTPStreamToken: UInt64 = 0
    private var nextHTTPStreamToken: UInt64 = 0

    func registerRunningProcess(_ process: Process, launched: Bool = true) -> UInt64 {
        runningProcessToken += 1
        runningProcess = process
        runningProcessLaunched = launched
        terminationRequestedBeforeLaunch = false
        return runningProcessToken
    }

    /// Marks a pre-launch registration as launched. Returns `false` when a
    /// termination request arrived before launch (or the registration is
    /// stale) — the caller must terminate the process it just started.
    func markProcessLaunched(token: UInt64) -> Bool {
        guard runningProcessToken == token, runningProcess != nil else { return false }
        runningProcessLaunched = true
        if terminationRequestedBeforeLaunch {
            runningProcess = nil
            return false
        }
        return true
    }

    func clearRunningProcess(token: UInt64) {
        guard runningProcessToken == token else { return }
        runningProcess = nil
    }

    private func requestProcessTermination() {
        guard runningProcess != nil else { return }
        if runningProcessLaunched {
            runningProcess?.terminate()
            runningProcess = nil
        } else {
            terminationRequestedBeforeLaunch = true
        }
    }

    func cancelRunningProcess(token: UInt64) {
        guard runningProcessToken == token else { return }
        requestProcessTermination()
    }

    /// T-TOOL-03: terminate the current spawned CLI process (if any) regardless of
    /// token. Used by grant revocation to kill an in-flight agent immediately
    /// while leaving the HTTP gateway stream untouched.
    func terminateRunningProcess() {
        requestProcessTermination()
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
        requestProcessTermination()
        httpStreamTask?.cancel()
        httpStreamTask = nil
        activeHTTPStreamToken = 0
    }
}
