import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Visible Terminal mission launch and sidecar process helpers.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module, verbatim.

extension CLIAgentMissionRequestListener {
    func runVisibleTerminalMission(
        executableName: String,
        arguments: [String],
        backend: CLIAgentMissionBackend,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        reference: DocumentReference,
        requestID: String,
        cancellationTracker: MissionCancellationTracker
    ) async -> DirectCLIMissionResult {
        guard let executable = await CLIExecutableResolver().resolveExecutable(named: executableName) else {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: "\(backend.displayName) CLI executable '\(executableName)' was not found on the Mac PATH.",
                sessionID: "visible-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }

        let sessionID = "visible-\(backend.rawValue)-\(UUID().uuidString)"
        do {
            await recordEvent(
                reference: reference,
                requestID: requestID,
                phase: "terminal_started",
                kind: "tool_call",
                title: "Terminal session",
                message: "Opening \(backend.displayName) in a visible Mac Terminal session.",
                backend: backend
            )
            let output = try await runVisibleTerminalProcess(
                sessionID: sessionID,
                executable: executable,
                executableName: executableName,
                arguments: arguments,
                backendDisplayName: backend.displayName,
                timeoutSeconds: 60 * 60,
                extraEnvironment: extraEnvironment,
                workingDirectoryURL: workingDirectoryURL,
                cancellationTracker: cancellationTracker,
                eventSink: { [weak self] event in
                    Task { @MainActor [weak self] in
                        await self?.recordEvent(
                            reference: reference,
                            requestID: requestID,
                            phase: event.phase,
                            kind: event.kind,
                            title: event.title,
                            message: event.message,
                            backend: backend,
                            toolName: event.toolName,
                            isError: event.isError
                        )
                    }
                }
            )
            return DirectCLIMissionResult(
                status: "completed",
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                errorMessage: nil,
                sessionID: sessionID
            )
        } catch {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: error.localizedDescription,
                sessionID: sessionID
            )
        }
    }

    nonisolated func runVisibleTerminalProcess(
        sessionID: String,
        executable: String,
        executableName: String,
        arguments: [String],
        backendDisplayName: String,
        timeoutSeconds: TimeInterval,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        cancellationTracker: MissionCancellationTracker,
        eventSink: @escaping @Sendable (DirectCLIStreamEvent) -> Void
    ) async throws -> String {
        let fileManager = FileManager.default
        let workspace = try VisibleTerminalSessionWorkspace.prepare(sessionID: sessionID, fileManager: fileManager)
        defer { workspace.cleanup() }

        let logURL = workspace.logURL
        let scriptURL = workspace.scriptURL
        let exitURL = workspace.exitURL
        let pidURL = workspace.pidURL
        let command = ([executable] + arguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")

        var scriptEnvironment = ["PATH": CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)["PATH"] ?? ""]
        scriptEnvironment.merge(extraEnvironment) { _, new in new }
        let exportLines = scriptEnvironment
            .filter { Self.isValidEnvironmentKey($0.key) }
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(Self.shellQuoted($0.value))" }
            .joined(separator: "\n")
        let cdLine = workingDirectoryURL.map { "cd \(Self.shellQuoted($0.path))" } ?? ""
        let script = """
        #!/bin/zsh
        set +e
        setopt pipefail
        echo $$ > \(Self.shellQuoted(pidURL.path))
        \(exportLines)
        \(cdLine)
        echo "OpenBurnBar visible CLI session"
        echo "Runtime: \(backendDisplayName)"
        echo "Executable: \(executableName)"
        echo ""
        ( \(command) ) 2>&1 | tee \(Self.shellQuoted(logURL.path))
        status=${pipestatus[1]}
        echo "$status" > \(Self.shellQuoted(exitURL.path))
        echo ""
        echo "OpenBurnBar visible CLI session finished with exit $status"
        exit "$status"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Terminal", scriptURL.path]
        try opener.run()
        opener.waitUntilExit()
        guard opener.terminationStatus == 0 else {
            throw NSError(
                domain: "OpenBurnBar.VisibleTerminalMission",
                code: Int(opener.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "macOS could not open Terminal for the visible CLI session."]
            )
        }

        eventSink(.toolCall("Terminal opened a visible \(backendDisplayName) CLI session.", title: "Terminal session", toolName: "Terminal"))

        let streamMirror = DirectCLIStreamMirror()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var offset: UInt64 = 0
        var output = ""
        var lastEventAt = Date.distantPast

        while Date() < deadline {
            if cancellationTracker.isCancelled {
                Self.killVisibleTerminalSession(pidURL: pidURL)
                throw NSError(
                    domain: "OpenBurnBar.VisibleTerminalMission",
                    code: 299,
                    userInfo: [NSLocalizedDescriptionKey: "Mission was cancelled by the user."]
                )
            }

            let chunk = Self.readVisibleTerminalLogChunk(logURL: logURL, offset: &offset)
            if !chunk.isEmpty {
                output += chunk
                let emittedStructuredEvents = streamMirror.consumeStdout(chunk, eventSink: eventSink)
                if !emittedStructuredEvents,
                   Date().timeIntervalSince(lastEventAt) >= 1,
                   let message = chunk.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    lastEventAt = Date()
                    eventSink(.assistant(message, title: "Terminal output"))
                }
            }

            if fileManager.fileExists(atPath: exitURL.path) {
                let finalChunk = Self.readVisibleTerminalLogChunk(logURL: logURL, offset: &offset)
                if !finalChunk.isEmpty {
                    output += finalChunk
                    _ = streamMirror.consumeStdout(finalChunk, eventSink: eventSink)
                }
                // try?-ok(sidecar read fallback)
                let rawStatus = (try? String(contentsOf: exitURL, encoding: .utf8))
                    ?? "1"
                let status = Int(rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
                let finalOutput = streamMirror.finalOutputSnapshot(fallback: output.nilIfEmpty ?? rawStatus)
                guard status == 0 else {
                    throw NSError(
                        domain: "OpenBurnBar.VisibleTerminalMission",
                        code: status,
                        userInfo: [NSLocalizedDescriptionKey: finalOutput.nilIfEmpty ?? "Visible \(backendDisplayName) CLI session failed with exit \(status)."]
                    )
                }
                return finalOutput
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch is CancellationError {
                // Task cancellation throws here and would skip the tracker/timeout
                // teardown below, so tear down the visible Terminal session now —
                // matching the former detached task, which reaped it via its
                // orphan running on to the deadline.
                Self.killVisibleTerminalSession(pidURL: pidURL)
                throw CancellationError()
            }
        }

        Self.killVisibleTerminalSession(pidURL: pidURL)
        throw NSError(
            domain: "OpenBurnBar.VisibleTerminalMission",
            code: 124,
            userInfo: [NSLocalizedDescriptionKey: "Visible \(backendDisplayName) CLI session timed out after \(Int(timeoutSeconds)) seconds."]
        )
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private nonisolated static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_").contains(first)
        else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        return key.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private nonisolated static func readVisibleTerminalLogChunk(
        logURL: URL,
        offset: inout UInt64
    ) -> String {
        guard FileManager.default.fileExists(atPath: logURL.path),
              // try?-ok(sidecar log read)
              let handle = try? FileHandle(forReadingFrom: logURL)
        else { return "" }
        defer { try? handle.close() } // try?-ok(handle teardown)
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private nonisolated static func killVisibleTerminalSession(pidURL: URL) {
        // try?-ok(sidecar pid read)
        guard let rawPID = try? String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(rawPID),
              pid > 0
        else { return }
        let killScript = """
        kill_tree() {
            local _pid=$1
            for _child in $(pgrep -P $_pid); do
                kill_tree $_child
            done
            kill -TERM $_pid 2>/dev/null
        }
        kill_tree \(pid)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", killScript]
        try? process.run() // try?-ok(fire-and-forget kill)
        process.waitUntilExit()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
