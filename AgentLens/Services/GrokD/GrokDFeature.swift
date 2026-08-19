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
    @discardableResult
    static func startLocalBoxIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        runner: (URL) throws -> Void = GrokDFeature.runEnsureScript
    ) -> Bool {
        guard isEnabled(defaults: defaults), isAutoStartEnabled(defaults: defaults) else { return false }
        guard !isAppSandboxed else { return false }
        let script = GrokDHostConfig.defaultEnsureLocalBoxURL()
        guard fileManager.isExecutableFile(atPath: script.path) || fileManager.fileExists(atPath: script.path) else {
            return false
        }
        do {
            try runner(script)
            return true
        } catch {
            return false
        }
    }

    static func runEnsureScript(_ script: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw GrokDHostError.transport("ensure-local-box \(process.terminationStatus)")
        }
    }
}
