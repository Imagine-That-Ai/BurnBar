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
    ///
    /// The blocking `Process` work runs off the main actor: this is a
    /// `nonisolated` `async` function, so callers on the main actor leave it
    /// when they `await` (SE-0338). Cancellation propagates from the awaiting
    /// task — do not reintroduce an unstructured detached task, which would sever it.
    static func run(executable: String, arguments: [String]) async throws -> String {
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
    }

    /// Launch `executable` and immediately return, with stdout/stderr/stdin
    /// detached. Used for long-lived companion apps (Hermes Dashboard, Pi
    /// app, etc.) that own their own lifecycle.
    ///
    /// Runs off the main actor (`nonisolated` `async`, SE-0338).
    static func launchDetached(executable: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
