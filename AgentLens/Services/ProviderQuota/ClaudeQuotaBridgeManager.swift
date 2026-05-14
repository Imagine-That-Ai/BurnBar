import Foundation

private struct ClaudeQuotaBridgeCommandSpec: Codable, Equatable {
    let executable: String
    let arguments: [String]

    var jsonObject: [String: Any] {
        [
            "executable": executable,
            "arguments": arguments
        ]
    }

    static func fromJSONObject(_ value: Any?) -> ClaudeQuotaBridgeCommandSpec? {
        guard let dictionary = value as? [String: Any] else { return nil }
        guard let executable = dictionary["executable"] as? String else { return nil }
        guard let arguments = dictionary["arguments"] as? [String] else { return nil }
        let trimmedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExecutable.isEmpty else { return nil }
        return ClaudeQuotaBridgeCommandSpec(executable: trimmedExecutable, arguments: arguments)
    }
}

struct ClaudeQuotaBridgeManager {
    let appPaths: OpenBurnBarAppPaths
    let homeDirectoryURL: URL
    let fileManager: FileManager
    let snapshotStore: ProviderQuotaSnapshotStore

    func installClaudeQuotaBridge() throws {
        let settingsURL = homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")

        let wrapperURL = appPaths.claudeStatuslineBridgeScriptURL
        let metadataURL = appPaths.claudeStatuslineBridgeMetadataURL
        let snapshotURL = appPaths.claudeStatuslineSnapshotURL

        try snapshotStore.ensureParentDirectory(for: settingsURL)
        try snapshotStore.ensureParentDirectory(for: wrapperURL)
        try snapshotStore.ensureParentDirectory(for: metadataURL)

        var settings = try snapshotStore.readJSONObject(from: settingsURL) ?? [:]
        let currentStatusLine = settings["statusLine"]
        let metadata = (try snapshotStore.readJSONObject(from: metadataURL)) ?? [:]

        let wrapperCommand = wrapperURL.path
        let currentCommand = command(fromStatusLine: currentStatusLine)
        let isAlreadyBridge = currentCommand == wrapperCommand
            || currentCommand == "'\(wrapperCommand.replacingOccurrences(of: "'", with: "'\\''"))'"
        let originalStatusLineCandidate: Any? = if isAlreadyBridge {
            metadata["originalStatusLine"]
        } else {
            currentStatusLine
        }
        let originalStatusLine = sanitizedOriginalStatusLine(
            originalStatusLineCandidate,
            wrapperPath: wrapperCommand
        )

        let originalCommandSpec = originalCommandSpec(
            from: originalStatusLine,
            existingMetadata: metadata,
            wrapperPath: wrapperCommand
        )
        try writeClaudeBridgeWrapper(
            to: wrapperURL,
            snapshotPath: snapshotURL.path,
            metadataPath: metadataURL.path
        )

        try snapshotStore.writeJSONObject(
            [
                "originalStatusLine": originalStatusLine,
                "originalCommandSpec": originalCommandSpec?.jsonObject ?? NSNull(),
                "installedAt": ISO8601DateFormatter().string(from: Date()),
                "wrapperPath": wrapperURL.path
            ],
            to: metadataURL
        )

        // Shell-escape the path in case it contains spaces (e.g. "Application Support").
        // Claude Code runs the command via sh -c, so unquoted spaces break execution.
        let shellSafeCommand = wrapperCommand.contains(" ")
            ? "'\(wrapperCommand.replacingOccurrences(of: "'", with: "'\\''"))'"
            : wrapperCommand
        settings["statusLine"] = [
            "type": "command",
            "command": shellSafeCommand,
        ]
        try snapshotStore.writeJSONObject(settings, to: settingsURL)
    }

    func removeClaudeQuotaBridge() throws {
        let settingsURL = homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        let metadataURL = appPaths.claudeStatuslineBridgeMetadataURL

        guard var settings = try snapshotStore.readJSONObject(from: settingsURL) else {
            return
        }

        let metadata = try snapshotStore.readJSONObject(from: metadataURL)
        if let originalStatusLine = metadata?["originalStatusLine"] {
            if originalStatusLine is NSNull {
                settings.removeValue(forKey: "statusLine")
            } else {
                settings["statusLine"] = originalStatusLine
            }
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try snapshotStore.writeJSONObject(settings, to: settingsURL)

        try? fileManager.removeItem(at: metadataURL)
        try? fileManager.removeItem(at: appPaths.claudeStatuslineBridgeScriptURL)
    }

    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        let wrapperPath = appPaths.claudeStatuslineBridgeScriptURL.path
        let snapshotURL = appPaths.claudeStatuslineSnapshotURL
        let settingsURL = homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")

        guard let settings = ((try? snapshotStore.readJSONObject(from: settingsURL)) ?? nil) else {
            return ClaudeQuotaBridgeStatus(
                state: .notInstalled,
                wrapperPath: wrapperPath,
                detailText: "Claude settings were not found. OpenBurnBar can install a global status line bridge in ~/.claude/settings.json.",
                lastPayloadAt: nil
            )
        }

        let disableAllHooks = (settings["disableAllHooks"] as? Bool) == true
        let configuredCommand = command(fromStatusLine: settings["statusLine"])
        let snapshotDate = snapshotStore.modificationDate(for: snapshotURL)

        // Match both raw path and shell-escaped path (e.g. with wrapping single-quotes)
        let isBridgeInstalled = configuredCommand == wrapperPath
            || configuredCommand == "'\(wrapperPath.replacingOccurrences(of: "'", with: "'\\''"))'"
        if isBridgeInstalled {
            if disableAllHooks {
                return ClaudeQuotaBridgeStatus(
                    state: .disabledByHooks,
                    wrapperPath: wrapperPath,
                    detailText: "Claude has disableAllHooks=true, so status line commands will not run until hooks are re-enabled.",
                    lastPayloadAt: snapshotDate
                )
            }

            if snapshotDate == nil {
                return ClaudeQuotaBridgeStatus(
                    state: .awaitingFirstPayload,
                    wrapperPath: wrapperPath,
                    detailText: "Bridge installed but no data yet. The status line hook is CLI-only — send a prompt via the Claude Code CLI (not VS Code extension) to capture rate-limit JSON.",
                    lastPayloadAt: nil
                )
            } else {
                return ClaudeQuotaBridgeStatus(
                    state: .ready,
                    wrapperPath: wrapperPath,
                    detailText: "Bridge installed and receiving Claude status line payloads.",
                    lastPayloadAt: snapshotDate
                )
            }
        }

        let detail: String
        if settings["statusLine"] != nil {
            detail = "Claude already has a custom status line command. OpenBurnBar can wrap and preserve it if you enable the bridge."
        } else {
            detail = "Enable OpenBurnBar's status line bridge to capture Claude quota updates."
        }
        return ClaudeQuotaBridgeStatus(
            state: configuredCommand == nil ? .notInstalled : .invalidConfiguration,
            wrapperPath: wrapperPath,
            detailText: detail,
            lastPayloadAt: snapshotDate
        )
    }

    // MARK: - Helpers

    func command(fromStatusLine value: Any?) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        guard (dictionary["type"] as? String)?.lowercased() == "command" else { return nil }
        return dictionary["command"] as? String
    }

    func writeClaudeBridgeWrapper(to url: URL, snapshotPath: String, metadataPath: String) throws {
        let script = """
        #!/bin/sh
        set -eu

        SNAPSHOT_PATH='\(snapshotPath)'
        METADATA_PATH='\(metadataPath)'
        TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/openburnbar-claude-statusline.XXXXXX")"
        trap 'rm -f "$TMP_FILE"' EXIT

        cat > "$TMP_FILE"
        cp "$TMP_FILE" "$SNAPSHOT_PATH"

        if [ -f "$METADATA_PATH" ]; then
          /usr/bin/python3 - "$METADATA_PATH" "$TMP_FILE" <<'PY'
        import json
        import os
        import subprocess
        import sys

        try:
            with open(sys.argv[1], 'r', encoding='utf-8') as fh:
                payload = json.load(fh)
            spec = payload.get('originalCommandSpec')
            if not isinstance(spec, dict):
                raise SystemExit(0)

            executable = spec.get('executable')
            arguments = spec.get('arguments') or []
            if not isinstance(executable, str) or not executable:
                raise SystemExit(0)
            if not isinstance(arguments, list) or any(not isinstance(arg, str) for arg in arguments):
                raise SystemExit(0)
            wrapper_path = payload.get('wrapperPath')
            if isinstance(wrapper_path, str) and wrapper_path:
                if executable == wrapper_path or os.path.realpath(executable) == os.path.realpath(wrapper_path):
                    raise SystemExit(0)

            with open(sys.argv[2], 'rb') as stdin_fh:
                subprocess.run([executable, *arguments], stdin=stdin_fh, check=False)
        except Exception:
            pass
        PY
        fi
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func sanitizedOriginalStatusLine(_ statusLine: Any?, wrapperPath: String) -> Any {
        guard let statusLine, !(statusLine is NSNull) else { return NSNull() }
        if isBridgeCommand(command(fromStatusLine: statusLine), wrapperPath: wrapperPath) {
            return NSNull()
        }
        return statusLine
    }

    private func originalCommandSpec(
        from statusLine: Any?,
        existingMetadata: [String: Any],
        wrapperPath: String
    ) -> ClaudeQuotaBridgeCommandSpec? {
        if let existingSpec = ClaudeQuotaBridgeCommandSpec.fromJSONObject(existingMetadata["originalCommandSpec"]),
           !isBridgeSpec(existingSpec, wrapperPath: wrapperPath) {
            return existingSpec
        }

        if let spec = commandSpec(fromStatusLine: statusLine),
           !isBridgeSpec(spec, wrapperPath: wrapperPath) {
            return spec
        }

        if let legacyCommand = existingMetadata["originalCommand"] as? String,
           !isBridgeCommand(legacyCommand, wrapperPath: wrapperPath) {
            return commandSpec(fromCommandString: legacyCommand)
        }

        return nil
    }

    private func isBridgeSpec(_ spec: ClaudeQuotaBridgeCommandSpec, wrapperPath: String) -> Bool {
        spec.executable == wrapperPath
            || URL(fileURLWithPath: spec.executable).standardizedFileURL == URL(fileURLWithPath: wrapperPath).standardizedFileURL
    }

    private func isBridgeCommand(_ command: String?, wrapperPath: String) -> Bool {
        guard let command else { return false }
        if command == wrapperPath || command == "'\(wrapperPath.replacingOccurrences(of: "'", with: "'\\''"))'" {
            return true
        }
        guard let spec = commandSpec(fromCommandString: command) else { return false }
        return isBridgeSpec(spec, wrapperPath: wrapperPath)
    }

    private func commandSpec(fromStatusLine value: Any?) -> ClaudeQuotaBridgeCommandSpec? {
        guard let command = command(fromStatusLine: value) else { return nil }
        return commandSpec(fromCommandString: command)
    }

    private func commandSpec(fromCommandString command: String) -> ClaudeQuotaBridgeCommandSpec? {
        guard let components = shellSplit(command), let executable = components.first else {
            return nil
        }
        return ClaudeQuotaBridgeCommandSpec(
            executable: executable,
            arguments: Array(components.dropFirst())
        )
    }

    private func shellSplit(_ command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        func rejectUnsafeMetacharacter(_ character: Character) -> Bool {
            switch character {
            case "|", "&", ";", "<", ">", "(", ")", "$", "`":
                return true
            default:
                return false
            }
        }

        for character in command {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            if rejectUnsafeMetacharacter(character) {
                return nil
            }

            current.append(character)
        }

        guard !isEscaping, quote == nil else { return nil }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens.isEmpty ? nil : tokens
    }
}
