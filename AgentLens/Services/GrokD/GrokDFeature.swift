import Foundation

/// Local D box feature flags. Defaults OFF. No catalog / Hermes / quota identity.
enum GrokDFeature {
    enum DefaultsKey {
        static let enabled = "localD.box.enabled"
        static let autoStart = "localD.box.autoStart"
    }

    static func boxTitle(liveCount: Int) -> String {
        "Local D box (\(liveCount) live agents)"
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: DefaultsKey.enabled)
    }

    static func isAutoStartEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: DefaultsKey.autoStart)
    }

    static var isAppSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Runs `ensure-local-box.sh` once when enabled, auto-start is on, and the process is not sandboxed.
    /// Never launches `grokd-local`, D.app, or Seat4.
    /// The process wait is async (`terminationHandler`) so Settings never blocks on `@MainActor`.
    @discardableResult
    static func startLocalBoxIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        runner: @escaping (URL) async throws -> Void = GrokDFeature.runEnsureScript
    ) async -> Bool {
        guard isEnabled(defaults: defaults), isAutoStartEnabled(defaults: defaults) else { return false }
        guard !isAppSandboxed else { return false }
        let script = GrokDHostConfig.defaultEnsureLocalBoxURL()
        guard fileManager.isExecutableFile(atPath: script.path) || fileManager.fileExists(atPath: script.path) else {
            return false
        }
        do {
            try await runner(script)
            return true
        } catch {
            return false
        }
    }

    static func runEnsureScript(_ script: URL) async throws {
        let box = GrokDEnsureProcess()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.continuation = continuation
            let process = box.process
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                let cont = box.continuation
                box.continuation = nil
                if proc.terminationStatus == 0 {
                    cont?.resume(returning: ())
                } else {
                    cont?.resume(throwing: GrokDHostError.transport("ensure-local-box \(proc.terminationStatus)"))
                }
            }
            do {
                try process.run()
            } catch {
                box.continuation = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Retains `Process` until `terminationHandler` fires. The continuation
/// setup closure returns immediately; without this box the process is
/// released mid-run.
private final class GrokDEnsureProcess: @unchecked Sendable {
    let process = Process()
    var continuation: CheckedContinuation<Void, Error>?
}
