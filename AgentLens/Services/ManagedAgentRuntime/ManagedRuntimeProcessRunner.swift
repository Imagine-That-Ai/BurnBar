import Foundation

// MARK: - Managed Runtime Process Runner

/// Shared process invocation surface used by every managed runtime adapter.
/// Pulled out of `HermesRuntimeProcessRunner` so Pi (and any future adapters)
/// reuse the exact same launch semantics: enriched PATH, output piping for
/// blocking commands, and `nullDevice`-attached detached processes.
enum ManagedRuntimeProcessRunner {
    /// Generic command-failed error so callers don't need to depend on a
    /// specific adapter's `LocalizedError` cases.
    struct CommandFailedError: Error, LocalizedError, Equatable {
        let command: String
        let detail: String

        var errorDescription: String? {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(command) failed." : "\(command) failed: \(trimmed)"
        }
    }

    /// Run `executable` synchronously, return its merged stdout/stderr.
    static func run(executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
            process.standardInput = FileHandle.nullDevice

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                let command = ([executable] + arguments).joined(separator: " ")
                throw CommandFailedError(
                    command: command,
                    detail: error.isEmpty ? output : error
                )
            }
            return output.isEmpty ? error : output
        }.value
    }

    /// Launch `executable` and immediately return, with stdout/stderr/stdin
    /// detached. Used for long-lived companion apps (Hermes Dashboard, Pi
    /// app, etc.) that own their own lifecycle.
    static func launchDetached(executable: String, arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }.value
    }
}
