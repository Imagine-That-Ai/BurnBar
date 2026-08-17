import Foundation

/// Spawns a real `/bin/sleep` process so probes can verify liveness against a
/// genuine live pid. The process is terminated in teardown — it is a process
/// the test itself started (the mission never touches other processes).
final class LiveSleepProcess {
    let process: Process
    let pid: Int32

    init() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["300"]
        try process.run()
        self.process = process
        self.pid = process.processIdentifier
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Writes a JSON document to `path`, creating parent directories.
func writeJSONFixture(_ object: Any, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(withJSONObject: object)
    try data.write(to: url)
}

/// Sets a file's modification date (fake mtimes for freshness tests).
func setFileMtime(_ date: Date, at path: String) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: path
    )
}
