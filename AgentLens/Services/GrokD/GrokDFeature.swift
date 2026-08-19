import Foundation
import os

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

    /// Runs `ensure-local-box.sh` at most once per process when enabled and auto-start is on.
    /// Never launches `grokd-local`, D.app, or Seat4.
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
        if GrokDEnsureOnce.ran.withLock({ $0 }) { return }
        let path = script.path
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw GrokDHostError.transport("ensure-local-box launch failed")
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            if status != 0 {
                throw GrokDHostError.transport("ensure-local-box \(status)")
            }
        }.value
        GrokDEnsureOnce.ran.withLock { $0 = true }
    }
}

private enum GrokDEnsureOnce {
    static let ran = OSAllocatedUnfairLock(initialState: false)
}
