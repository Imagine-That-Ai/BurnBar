import Foundation

// MARK: - CLI Bridge

@MainActor
final class CLIBridge: ObservableObject {
    enum Backend: Equatable {
        case claudeCode(path: String)
        case codex(path: String)
    }

    private(set) var detectedBackend: Backend?

    private var runningProcess: Process?

    func detect() async {
        if let path = await resolveExecutable(named: "claude") {
            detectedBackend = .claudeCode(path: path)
            return
        }
        if let path = await resolveExecutable(named: "codex") {
            detectedBackend = .codex(path: path)
            return
        }
        detectedBackend = nil
    }

    func cancel() {
        runningProcess?.terminate()
        runningProcess = nil
    }

    /// Streams assistant text from the detected CLI (Claude `--output-format stream-json`, or Codex `exec --json` JSONL).
    func chat(systemPrompt: String, userMessage: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let backend = await MainActor.run { self.detectedBackend }
                guard let backend else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }

                let fullPrompt = """
                \(systemPrompt)

                User:
                \(userMessage)
                """

                switch backend {
                case .claudeCode(let path):
                    await self.runClaudeStream(
                        executable: path,
                        prompt: fullPrompt,
                        continuation: continuation
                    )
                case .codex(let path):
                    await self.runCodexStream(
                        executable: path,
                        prompt: fullPrompt,
                        continuation: continuation
                    )
                }
            }
        }
    }

    nonisolated private func runClaudeStream(
        executable: String,
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.claudeArguments(prompt: prompt)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        await MainActor.run {
            self.runningProcess = process
        }

        do {
            try process.run()
        } catch {
            await MainActor.run { self.runningProcess = nil }
            continuation.finish(throwing: error)
            return
        }

        let readHandle = pipe.fileHandleForReading
        while let line = readHandle.readLine() {
            if let text = Self.extractStreamJSONText(from: line) {
                continuation.yield(text)
            }
        }

        process.waitUntilExit()

        await MainActor.run { self.runningProcess = nil }

        if process.terminationStatus != 0, process.terminationStatus != 15 {
            continuation.finish(throwing: CLIBridgeError.processExit(code: Int(process.terminationStatus)))
            return
        }
        continuation.finish()
    }

    /// `codex exec --json` writes JSON Lines to stdout while the run is in progress (see OpenAI Codex non-interactive docs).
    nonisolated private func runCodexStream(
        executable: String,
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.codexArguments(prompt: prompt)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        await MainActor.run {
            self.runningProcess = process
        }

        do {
            try process.run()
        } catch {
            await MainActor.run { self.runningProcess = nil }
            continuation.finish(throwing: error)
            return
        }

        let readHandle = pipe.fileHandleForReading
        var lastAgentMessagePrefixLength = 0

        while let line = readHandle.readLine() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let type = obj["type"] as? String {
                if type == "turn.started" || type == "thread.started" {
                    lastAgentMessagePrefixLength = 0
                }
                if type == "error" {
                    let msg = (obj["message"] as? String)
                        ?? (obj["error"] as? String)
                        ?? "Codex reported an error"
                    continuation.finish(throwing: CLIBridgeError.codexEvent(msg))
                    await MainActor.run { self.runningProcess = nil }
                    return
                }
            }

            guard let fullText = Self.extractCodexAgentMessageText(from: obj), !fullText.isEmpty else {
                continue
            }

            if fullText.count < lastAgentMessagePrefixLength {
                lastAgentMessagePrefixLength = 0
            }

            if fullText.count > lastAgentMessagePrefixLength {
                let start = fullText.index(fullText.startIndex, offsetBy: lastAgentMessagePrefixLength)
                let delta = String(fullText[start...])
                lastAgentMessagePrefixLength = fullText.count
                if !delta.isEmpty {
                    continuation.yield(delta)
                }
            }
        }

        process.waitUntilExit()

        await MainActor.run { self.runningProcess = nil }

        if process.terminationStatus != 0, process.terminationStatus != 15 {
            continuation.finish(throwing: CLIBridgeError.processExit(code: Int(process.terminationStatus)))
            return
        }
        continuation.finish()
    }

    /// Pulls assistant-visible text from a Codex JSONL object (`codex exec --json`).
    nonisolated private static func extractCodexAgentMessageText(from obj: [String: Any]) -> String? {
        let type = obj["type"] as? String ?? ""

        if type == "item.completed" || type == "item.updated" || type == "item.started" {
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "agent_message" {
                if let text = item["text"] as? String { return text }
            }
        }

        if let item = obj["item"] as? [String: Any],
           (item["type"] as? String) == "agent_message",
           let text = item["text"] as? String {
            return text
        }

        if let message = obj["message"] as? [String: Any],
           let text = message["text"] as? String {
            return text
        }

        return nil
    }

    private func resolveExecutable(named name: String) async -> String? {
        await Task.detached {
            let env = ProcessInfo.processInfo.environment
            let fileManager = FileManager.default
            let homeDirectory = fileManager.homeDirectoryForCurrentUser.path

            if let path = Self.resolveExecutable(
                named: name,
                searchDirectories: Self.baseExecutableSearchDirectories(
                    environment: env,
                    homeDirectory: homeDirectory
                ),
                fileManager: fileManager
            ) {
                return path
            }

            if let path = Self.resolveExecutableFromLoginShell(
                named: name,
                environment: env,
                fileManager: fileManager
            ) {
                return path
            }

            if let path = Self.resolveExecutable(
                named: name,
                searchDirectories: Self.userManagedExecutableSearchDirectories(
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                ),
                fileManager: fileManager
            ) {
                return path
            }

            return nil
        }.value
    }

    nonisolated static func baseExecutableSearchDirectories(
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        return deduplicatedDirectories(pathEntries + [
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])
    }

    nonisolated static func userManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = [
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.asdf/shims",
            "\(homeDirectory)/.mise/shims"
        ]

        directories.append(contentsOf:
            contentsOfDirectory(
                atPath: "\(homeDirectory)/.nvm/versions/node",
                appending: "/bin",
                fileManager: fileManager
            )
        )

        directories.append(contentsOf:
            contentsOfDirectory(
                atPath: "\(homeDirectory)/.fnm/node-versions",
                appending: "/installation/bin",
                fileManager: fileManager
            )
        )

        return deduplicatedDirectories(directories)
    }

    nonisolated static func resolveExecutable(
        named name: String,
        searchDirectories: [String],
        fileManager: FileManager = .default
    ) -> String? {
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func resolveExecutableFromLoginShell(
        named name: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        let shellPath = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard fileManager.isExecutableFile(atPath: shellPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "command -v -- \(shellQuoted(name)) 2>/dev/null"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              let path = parseExecutablePath(fromCommandOutput: output),
              fileManager.isExecutableFile(atPath: path) else {
            return nil
        }

        return path
    }

    nonisolated static func parseExecutablePath(fromCommandOutput output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first(where: { $0.hasPrefix("/") })
    }

    nonisolated static func claudeArguments(prompt: String) -> [String] {
        [
            "-p",
            prompt,
            "--output-format",
            "stream-json",
            "--verbose"
        ]
    }

    nonisolated static func codexArguments(prompt: String) -> [String] {
        [
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            prompt
        ]
    }

    nonisolated private static func contentsOfDirectory(
        atPath path: String,
        appending suffix: String,
        fileManager: FileManager
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }

        return entries
            .sorted(by: >)
            .map { "\(path)/\($0)\(suffix)" }
    }

    nonisolated private static func deduplicatedDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()

        return directories.compactMap { directory in
            let expanded = NSString(string: directory).expandingTildeInPath
            guard !expanded.isEmpty else {
                return nil
            }

            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard seen.insert(standardized).inserted else {
                return nil
            }

            return standardized
        }
    }

    nonisolated private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    nonisolated private static func extractStreamJSONText(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let delta = obj["delta"] as? [String: Any] {
            if let text = delta["text"] as? String { return text }
            if let inner = delta["delta"] as? [String: Any], let text = inner["text"] as? String {
                return text
            }
        }

        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                if (block["type"] as? String) == "text", let text = block["text"] as? String {
                    return text
                }
            }
        }

        if let event = obj["event"] as? [String: Any],
           let delta = event["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }

        return nil
    }
}

enum CLIBridgeError: LocalizedError {
    case noCLI
    case processExit(code: Int)
    case codexEvent(String)

    var errorDescription: String? {
        switch self {
        case .noCLI:
            return "No claude or codex CLI found in PATH. Install one to use chat."
        case .processExit(let code):
            return "CLI exited with status \(code)."
        case .codexEvent(let message):
            return message
        }
    }
}
