import AppKit
import Darwin
import Foundation
import OpenBurnBarCore

@MainActor
final class SwitcherCLIAuthCoordinator {
    enum ReconnectResult: Equatable {
        case readyToPersist(SwitcherProfileRecord)
        case requiresConfirmation(updatedProfile: SwitcherProfileRecord, previousAccount: String?, detectedAccount: String?)
        case cancelled
        case failed(String)
    }

    struct ReconnectContext: Equatable {
        var providerSlotLabel: String?
        var existingAccountLabels: [String]

        init(providerSlotLabel: String? = nil, existingAccountLabels: [String] = []) {
            self.providerSlotLabel = providerSlotLabel
            self.existingAccountLabels = existingAccountLabels
        }
    }

    enum CLIExecutableHealth: Equatable {
        case healthy
        case broken(String)
    }

    struct Dependencies {
        var openScriptInTerminal: @Sendable (URL) async throws -> Void = { scriptURL in
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open(
                    [scriptURL],
                    withApplicationAt: terminalURL,
                    configuration: configuration
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }

        var discoverAuthState: @Sendable (SwitcherCLIProfileType, String?) -> CLIAuthInfo = { cliType, configDirectory in
            CLIAuthDiscovery.discoverAuthState(for: cliType, configDirectoryOverride: configDirectory)
        }

        var fileManager: FileManager = .default

        /// Resolves the on-disk executable path for a CLI type. Defaults to
        /// the production `CLILaunchAdapter` lookup; tests inject a closure
        /// that returns nil to exercise the "executable not installed" path.
        var executablePathResolver: @Sendable (SwitcherCLIProfileType) -> String? = { cliType in
            CLILaunchAdapter.executablePath(for: cliType)
        }

        var executableHealthChecker: @Sendable (SwitcherCLIProfileType, String) async -> CLIExecutableHealth = { cliType, executablePath in
            await SwitcherCLIAuthCoordinator.defaultExecutableHealth(cliType: cliType, executablePath: executablePath)
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    func reconnect(
        profile: SwitcherProfileRecord,
        context: ReconnectContext = ReconnectContext()
    ) async -> ReconnectResult {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType else {
            return .failed("Only Codex and Claude Code CLI profiles can reconnect.")
        }

        guard cliType == .codex || cliType == .claude else {
            return .failed("This CLI does not support account reconnect yet.")
        }

        guard let executablePath = dependencies.executablePathResolver(cliType) else {
            return .failed("\(cliType.displayName) is not installed.")
        }

        switch await dependencies.executableHealthChecker(cliType, executablePath) {
        case .healthy:
            break
        case .broken(let detail):
            return .failed(Self.actionableBrokenExecutableMessage(
                cliType: cliType,
                executablePath: executablePath,
                detail: detail
            ))
        }

        let preservesExistingAccount = normalized(profile.cliMetadata?.accountDescription) != nil
        let configDirectory = resolvedConfigDirectory(
            for: profile,
            cliType: cliType,
            preservesExistingAccount: preservesExistingAccount
        )

        do {
            try dependencies.fileManager.createDirectory(
                at: URL(fileURLWithPath: configDirectory),
                withIntermediateDirectories: true
            )
        } catch {
            return .failed("Failed to prepare profile auth directory: \(error.localizedDescription)")
        }

        let tempDirectory = dependencies.fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-cli-auth-\(UUID().uuidString)", isDirectory: true)
        let scriptURL = tempDirectory.appendingPathComponent("\(cliType.rawValue)-login.command")
        let markerURL = tempDirectory.appendingPathComponent("exit.status")
        let logURL = tempDirectory.appendingPathComponent("terminal.log")

        do {
            try dependencies.fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try writeScript(
                to: scriptURL,
                markerURL: markerURL,
                logURL: logURL,
                executablePath: executablePath,
                cliType: cliType,
                configDirectory: configDirectory,
                workingDirectory: profile.cliMetadata?.workingDirectory,
                context: context
            )
            try await dependencies.openScriptInTerminal(scriptURL)
        } catch {
            try? dependencies.fileManager.removeItem(at: tempDirectory)
            return .failed("Failed to start \(cliType.displayName) login in Terminal: \(error.localizedDescription)")
        }

        defer {
            try? dependencies.fileManager.removeItem(at: tempDirectory)
        }

        let terminationStatus = await waitForCompletion(markerURL: markerURL, timeout: 300)
        if terminationStatus == 130 || terminationStatus == 143 {
            return .cancelled
        }

        let authInfo = dependencies.discoverAuthState(cliType, configDirectory)
        guard isConnected(authInfo) else {
            let logTail = terminalLogTail(logURL: logURL)
            if let brokenDetail = Self.detectBrokenExecutableDetail(in: logTail) {
                return .failed(Self.actionableBrokenExecutableMessage(
                    cliType: cliType,
                    executablePath: executablePath,
                    detail: brokenDetail
                ))
            }
            if terminationStatus != 0 {
                let detail = logTail.map { " Last Terminal output: \($0)" } ?? ""
                return .failed("\(cliType.displayName) login did not complete successfully.\(detail)")
            }
            return .failed("\(cliType.displayName) login completed, but BurnBar could not verify the connected account.")
        }

        let updatedProfile = updatedProfileRecord(
            from: profile,
            cliType: cliType,
            configDirectory: configDirectory,
            detectedAccountDescription: authInfo.accountDescription
        )

        let previousAccount = normalized(profile.cliMetadata?.accountDescription)
        let detectedAccount = normalized(authInfo.accountDescription)
        if previousAccount != nil,
           detectedAccount != nil,
           previousAccount != detectedAccount {
            return .requiresConfirmation(
                updatedProfile: profileByClearingAccountScopedMetadata(updatedProfile),
                previousAccount: previousAccount,
                detectedAccount: detectedAccount
            )
        }

        return .readyToPersist(updatedProfile)
    }

    func isConnected(_ authInfo: CLIAuthInfo) -> Bool {
        switch authInfo.cliType {
        case .codex:
            switch authInfo.authState {
            case .authenticated, .apiKeyPresent:
                return true
            case .notAuthenticated, .notInstalled:
                return false
            }
        case .claude:
            if case .authenticated = authInfo.authState {
                return true
            }
            return false
        case .opencode:
            return false
        }
    }

    func resolvedConfigDirectory(
        for profile: SwitcherProfileRecord,
        cliType: SwitcherCLIProfileType,
        preservesExistingAccount: Bool
    ) -> String {
        let root = dependencies.fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBurnBar/SwitcherCLIProfiles", isDirectory: true)
            .appendingPathComponent(cliType.rawValue, isDirectory: true)

        if preservesExistingAccount {
            return root.appendingPathComponent(UUID().uuidString, isDirectory: true).path
        }

        if let existing = normalized(profile.cliMetadata?.configDirectory) {
            return existing
        }

        return root.appendingPathComponent(profile.id, isDirectory: true).path
    }

    func updatedProfileRecord(
        from profile: SwitcherProfileRecord,
        cliType: SwitcherCLIProfileType,
        configDirectory: String,
        detectedAccountDescription: String?
    ) -> SwitcherProfileRecord {
        let existingMetadata = profile.cliMetadata ?? SwitcherCLIProfileMetadata()
        return SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: configDirectory,
                accountDescription: normalized(detectedAccountDescription) ?? existingMetadata.accountDescription,
                providerID: existingMetadata.providerID,
                runtimeAccountID: existingMetadata.runtimeAccountID,
                subscriptionTierID: existingMetadata.subscriptionTierID,
                modelCapabilityClassID: existingMetadata.modelCapabilityClassID,
                linkedHarnessIDs: existingMetadata.linkedHarnessIDs,
                neverAutoSwitch: existingMetadata.neverAutoSwitch,
                lastQuotaExhaustedAt: existingMetadata.lastQuotaExhaustedAt,
                exhaustedUntil: existingMetadata.exhaustedUntil,
                lastQuotaExhaustionDetail: existingMetadata.lastQuotaExhaustionDetail,
                isDisabled: existingMetadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )
    }

    private func profileByClearingAccountScopedMetadata(_ profile: SwitcherProfileRecord) -> SwitcherProfileRecord {
        guard let cliType = profile.cliType,
              let metadata = profile.cliMetadata else {
            return profile
        }

        return SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: metadata.workingDirectory,
                additionalArgs: metadata.additionalArgs,
                envKeysToPass: metadata.envKeysToPass,
                displayLabel: metadata.displayLabel,
                configDirectory: metadata.configDirectory,
                accountDescription: metadata.accountDescription,
                providerID: metadata.providerID,
                runtimeAccountID: nil,
                subscriptionTierID: nil,
                modelCapabilityClassID: nil,
                linkedHarnessIDs: metadata.linkedHarnessIDs,
                neverAutoSwitch: metadata.neverAutoSwitch,
                lastQuotaExhaustedAt: nil,
                exhaustedUntil: nil,
                lastQuotaExhaustionDetail: nil,
                isDisabled: metadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt
        )
    }

    private func writeScript(
        to scriptURL: URL,
        markerURL: URL,
        logURL: URL,
        executablePath: String,
        cliType: SwitcherCLIProfileType,
        configDirectory: String,
        workingDirectory: String?,
        context: ReconnectContext
    ) throws {
        let commands = loginCommands(for: cliType, executablePath: executablePath)
        let configEnvKeys = configEnvironmentKeys(for: cliType)
        let slotLabel = normalized(context.providerSlotLabel) ?? "\(cliType.displayName) reserve"
        let existingAccounts = context.existingAccountLabels
            .compactMap(normalized)
            .prefix(6)

        var lines: [String] = [
            "#!/bin/zsh",
            "set +e",
            "STATUS=1",
            "trap 'printf \"%s\" \"$STATUS\" > \(shellEscape(markerURL.path))' EXIT",
            "exec > >(tee -a \(shellEscape(logURL.path))) 2>&1",
            "mkdir -p \(shellEscape(configDirectory))",
            "clear",
            "echo 'OpenBurnBar is adding \(shellSingleLine(slotLabel))'",
            "echo 'Provider: \(shellSingleLine(cliType.displayName))'",
            "echo 'Auth directory: \(shellSingleLine(configDirectory))'",
            "echo ''",
            "echo 'Important: choose a DIFFERENT \(shellSingleLine(cliType.displayName)) account if you want to add a new reserve.'"
        ]

        if !existingAccounts.isEmpty {
            lines.append("echo 'Already added accounts:'")
            for account in existingAccounts {
                lines.append("echo '  - \(shellSingleLine(account))'")
            }
        }

        lines.append(contentsOf: [
            "echo ''",
            "echo 'When the login finishes, close this Terminal window or let it exit. BurnBar will verify the detected account.'",
            "echo '------------------------------------------------------------'",
            "echo ''"
        ])

        if let workingDirectory = normalized(workingDirectory) {
            lines.append("cd \(shellEscape(workingDirectory)) || exit 1")
        }

        for configEnvKey in configEnvKeys {
            lines.append("export \(configEnvKey)=\(shellEscape(configDirectory))")
        }

        if let first = commands.first {
            lines.append("echo 'Running: \(shellSingleLine(first))'")
            lines.append(first)
            lines.append("STATUS=$?")
        }

        if commands.count > 1, let second = commands.dropFirst().first {
            lines.append("if [[ $STATUS -ne 0 && $STATUS -ne 130 && $STATUS -ne 143 ]]; then")
            lines.append("  echo ''")
            lines.append("  echo 'First login command failed; trying fallback command.'")
            lines.append("  echo 'Running: \(shellSingleLine(second))'")
            lines.append("  \(second)")
            lines.append("  STATUS=$?")
            lines.append("fi")
        }

        lines.append("if [[ $STATUS -ne 0 && $STATUS -ne 130 && $STATUS -ne 143 ]]; then")
        lines.append("  echo ''")
        lines.append("  echo 'OpenBurnBar could not complete \(shellSingleLine(cliType.displayName)) login.'")
        lines.append("  echo 'If this says spawn ENOENT or macOS blocked malware, reinstall \(shellSingleLine(cliType.displayName)) and retry.'")
        lines.append("fi")
        lines.append("echo ''")
        lines.append("echo 'Login command exited with status:' $STATUS")
        lines.append("exit $STATUS")

        let contents = lines.joined(separator: "\n")
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try dependencies.fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    func loginCommands(for cliType: SwitcherCLIProfileType, executablePath: String) -> [String] {
        let candidates: [[String]]
        switch cliType {
        case .codex:
            candidates = [["login"], ["auth", "login"]]
        case .claude:
            candidates = [["auth", "login"], ["login"]]
        case .opencode:
            candidates = []
        }

        return candidates.map { args in
            ([executablePath] + args).map(shellEscape).joined(separator: " ")
        }
    }

    func configEnvironmentKeys(for cliType: SwitcherCLIProfileType) -> [String] {
        switch cliType {
        case .codex:
            return ["CODEX_HOME", "CODEX_CONFIG_PATH"]
        case .claude:
            return ["CLAUDE_CONFIG_DIR", "CLAUDE_CONFIG_PATH"]
        case .opencode:
            return []
        }
    }

    private func waitForCompletion(markerURL: URL, timeout: TimeInterval) async -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = dependencies.fileManager.contents(atPath: markerURL.path),
               let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let value = Int32(raw) {
                return value
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return 124
    }

    func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func terminalLogTail(logURL: URL, maxBytes: Int = 8_192) -> String? {
        guard let data = dependencies.fileManager.contents(atPath: logURL.path), !data.isEmpty else {
            return nil
        }
        let tailData: Data
        if data.count > maxBytes {
            tailData = data.suffix(maxBytes)
        } else {
            tailData = data
        }
        guard let text = String(data: tailData, encoding: .utf8) else { return nil }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .suffix(12)
            .map(String.init)
        let redacted = lines.joined(separator: " ")
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._\-]+"#, with: "Bearer [redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]+"#, with: "sk-[redacted]", options: .regularExpression)
        return redacted.isEmpty ? nil : redacted
    }

    private func shellSingleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "'", with: "'\"'\"'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    nonisolated private static func defaultExecutableHealth(
        cliType: SwitcherCLIProfileType,
        executablePath: String
    ) async -> CLIExecutableHealth {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["--version"]
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                return .broken(error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline {
                Darwin.usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
                return .healthy
            }
            process.waitUntilExit()

            let output = [
                String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ]
                .compactMap { $0 }
                .joined(separator: "\n")

            if let detail = detectBrokenExecutableDetail(in: output) {
                return .broken(detail)
            }

            // Some CLIs return non-zero for --version under unusual install
            // modes, but only known wrapper/native-binary failures block login.
            _ = cliType
            return .healthy
        }.value
    }

    nonisolated static func detectBrokenExecutableDetail(in output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        let lowercased = output.lowercased()
        if lowercased.contains(" enoent")
            || lowercased.contains("code: 'enoent'")
            || lowercased.contains("spawn ") && lowercased.contains("enoent")
            || lowercased.contains("malware blocked") {
            return output
        }
        return nil
    }

    nonisolated static func actionableBrokenExecutableMessage(
        cliType: SwitcherCLIProfileType,
        executablePath: String,
        detail: String
    ) -> String {
        let installHint: String
        switch cliType {
        case .codex:
            installHint = "Reinstall Codex with `npm uninstall -g @openai/codex && npm install -g @openai/codex`, then retry Add Account."
        case .claude:
            installHint = "Reinstall Claude Code from its official installer or npm package, then retry Add Account."
        case .opencode:
            installHint = "Reinstall OpenCode, then retry Add Account."
        }

        let reason: String
        if detail.localizedCaseInsensitiveContains("malware") {
            reason = "macOS blocked or removed the native \(cliType.displayName) binary."
        } else {
            reason = "the \(cliType.displayName) wrapper is present, but its native binary is missing."
        }

        return "\(cliType.displayName) cannot open its login prompt because \(reason) Resolved wrapper: \(executablePath). \(installHint)"
    }
}
