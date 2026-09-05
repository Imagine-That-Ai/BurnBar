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
            try? dependencies.fileManager.removeItem(at: tempDirectory) // try?-ok(temp cleanup)
            return .failed("Failed to start \(cliType.displayName) login in Terminal: \(error.localizedDescription)")
        }

        defer {
            try? dependencies.fileManager.removeItem(at: tempDirectory) // try?-ok(temp cleanup)
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

        // Credential persistence is deliberately NOT done here. A successful
        // login must yield a saved switcher profile even if the (best-effort,
        // possibly ACL-gated) route-token snapshot fails. The caller persists
        // the profile first, then snapshots the credential non-fatally via
        // `persistProfileCredentialAfterConfirmedLogin(for:)`.
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
        case .droid, .forge, .antigravity, .grok, .cursorAgent, .gemini, .kimi, .pi, .omp, .junie, .primeAgent, .fx, .muse, .hermes, .goose, .windsurf, .openClaude, .openClaw:
            if case .authenticated = authInfo.authState {
                return true
            }
            if case .apiKeyPresent = authInfo.authState {
                return true
            }
            return false
        @unknown default:
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
        case .opencode, .droid, .forge, .antigravity, .grok, .cursorAgent, .gemini, .kimi, .pi, .omp, .junie, .primeAgent, .fx, .muse, .hermes, .goose, .windsurf, .openClaude, .openClaw:
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
        case .droid:
            return ["FACTORY_HOME", "DROID_HOME"]
        case .forge:
            return ["FORGE_HOME", "FORGE_CONFIG_HOME"]
        case .antigravity:
            return ["AGY_CONFIG_HOME", "ANTIGRAVITY_HOME", "GEMINI_HOME"]
        case .grok:
            return ["GROK_HOME", "XAI_API_KEY"]
        case .cursorAgent:
            return ["CURSOR_AGENT_HOME", "CURSOR_AGENT_CONFIG_PATH"]
        case .gemini:
            return ["GEMINI_HOME", "GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .kimi:
            return ["KIMI_HOME", "KIMI_API_KEY", "MOONSHOT_API_KEY"]
        case .pi:
            return ["PI_HOME", "PI_CONFIG_HOME"]
        case .junie:
            return ["JUNIE_HOME"]
        case .fx:
            return ["FX_HOME"]
        case .muse:
            // No documented MUSE_* home override; auth is browser-linked.
            return []
        case .omp:
            return ["OMP_HOME", "OMP_CONFIG_HOME"]
        case .primeAgent:
            return ["PRIME_HOME", "PRIME_AGENT_HOME"]
        case .hermes:
            return ["HERMES_HOME", "HERMES_CONFIG_PATH"]
        case .goose:
            return ["GOOSE_HOME", "GOOSE_PATH_ROOT"]
        case .windsurf:
            return ["WINDSURF_HOME", "CODEIUM_HOME"]
        case .openClaude:
            return ["OPENCLAUDE_CONFIG_DIR"]
        case .openClaw:
            return ["OPENCLAW_HOME", "OPENCLAW_CONFIG_PATH"]
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

            try? await Task.sleep(nanoseconds: 500_000_000) // try?-ok(cancellation only)
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
        case .droid:
            installHint = "Reinstall Factory Droid, then retry Add Account."
        case .forge:
            installHint = "Reinstall Forge, then retry Add Account."
        case .antigravity:
            installHint = "Reinstall Google Antigravity, then retry Add Account."
        case .grok:
            installHint = "Reinstall Grok Build CLI, then retry Add Account."
        case .cursorAgent:
            installHint = "Reinstall Cursor Agent, then retry Add Account."
        case .gemini:
            installHint = "Reinstall Gemini CLI, then retry Add Account."
        case .kimi:
            installHint = "Reinstall Kimi, then retry Add Account."
        case .pi:
            installHint = "Reinstall Pi, then retry Add Account."
        case .junie:
            installHint = "Reinstall JetBrains Junie (curl -fsSL https://junie.jetbrains.com/install.sh | bash), then retry Add Account."
        case .fx:
            installHint = "Reinstall Vercel fx (curl -fsSL https://fx.sh/install.sh | bash), then retry Add Account."
        case .muse:
            installHint = "Reinstall Muse Code (curl -fsSL https://dev.meta.ai/install.sh | bash), then retry Add Account."
        case .omp:
            installHint = "Reinstall OMP, then retry Add Account."
        case .primeAgent:
            installHint = "Reinstall Prime Agent (npm install -g prime-agent), then retry Add Account."
        case .hermes:
            installHint = "Reinstall Hermes, then retry Add Account."
        case .goose:
            installHint = "Reinstall Goose (curl -fsSL https://github.com/block/goose/releases | bash), then retry Add Account."
        case .windsurf:
            installHint = "Reinstall Windsurf from codeium.com/windsurf, then retry Add Account."
        case .openClaude:
            installHint = "Reinstall OpenClaude, then retry Add Account."
        case .openClaw:
            installHint = "Reinstall OpenClaw, then retry Add Account."
        }

        let reason: String
        if detail.localizedCaseInsensitiveContains("malware") {
            reason = "macOS blocked or removed the native \(cliType.displayName) binary."
        } else {
            reason = "the \(cliType.displayName) wrapper is present, but its native binary is missing."
        }

        return "\(cliType.displayName) cannot open its login prompt because \(reason) Resolved wrapper: \(executablePath). \(installHint)"
    }

    nonisolated static func persistProfileCredentialAfterConfirmedLogin(for profile: SwitcherProfileRecord) throws {
        guard profile.cliType == .claude,
              let configDirectory = normalizedCredentialDirectory(profile.cliMetadata?.configDirectory) else {
            return
        }

        try persistClaudeProfileCredential(
            configDirectory: configDirectory,
            expectedAccountDescription: normalizedCredentialDirectory(profile.cliMetadata?.accountDescription)
        )
    }

    /// Snapshots the *auto-detected default* local Claude login (`~/.claude`)
    /// into the per-profile Keychain item the quota reader resolves.
    ///
    /// Unlike a saved isolated profile, the default login has no
    /// `SwitcherProfileRecord` — it is discovered live from the global Claude
    /// Code session — so background quota refresh, which reads the per-profile
    /// item with `allowDefaultKeychainFallback: false`, finds nothing and shows
    /// blank quota. This is the only user-facing moment (the "Refresh
    /// credential" action) where macOS can present the "Always Allow" prompt
    /// that lets BurnBar copy the ACL-locked global token into its own
    /// per-profile item; the background refresh is non-interactive and cannot
    /// prompt.
    ///
    /// Delegates to the same capture+persist path as a confirmed login, so the
    /// captured payload lands in `profileScopedKeychainService(configDirectory:)`
    /// and the next background refresh reads it back. Throws `.accessDenied`
    /// (actionable ACL message) when the global item exists but macOS blocks the
    /// read, so the caller can guide the user to grant access.
    ///
    /// No account-match guard is applied (`expectedAccountDescription: nil`):
    /// this is the *live* default login, so the global item it captures already
    /// belongs to it. The guard exists only to stop a saved second-subscription
    /// profile from grabbing the default login's token during interleaved
    /// logins, which cannot happen here.
    nonisolated static func captureDefaultLoginProfileCredential(
        configDirectory: String
    ) throws {
        guard let configDirectory = normalizedCredentialDirectory(configDirectory) else {
            return
        }

        try persistClaudeProfileCredential(
            configDirectory: configDirectory,
            expectedAccountDescription: nil
        )
    }

    /// Snapshots the freshly signed-in Claude account's OAuth token into a
    /// BurnBar-owned, profile-scoped Keychain item so quota refresh can read it
    /// without ever touching Claude Code's own (cross-identity ACL-locked) global
    /// item again.
    ///
    /// macOS keeps one global Claude Code Keychain item that each `claude login`
    /// overwrites; `CLAUDE_CONFIG_DIR` does not scope it. So the only reliable
    /// capture window is right after this account's login, while it still owns
    /// the global item. We first check whether Claude already wrote a profile
    /// scoped item (some platforms/future versions do), and otherwise capture the
    /// global item — interactively, so macOS can prompt the user to grant access.
    ///
    /// The captured payload is written to BurnBar's own
    /// `profileScopedKeychainService(configDirectory:)` item, which the quota
    /// reader loads with `allowDefaultKeychainFallback: false`. Each distinct
    /// `configDirectory` hashes to a distinct service, so two subscriptions never
    /// resolve to each other's token.
    nonisolated private static func persistClaudeProfileCredential(
        configDirectory: String,
        expectedAccountDescription: String?
    ) throws {
        let profileImporter = ClaudeCodeOAuthCredentialImporter(
            configDirectory: configDirectory,
            allowDefaultKeychainFallback: false
        )
        let credentials: ClaudeOAuthCredentials
        do {
            credentials = try profileImporter.load(allowUserInteraction: false)
        } catch let error as ClaudeCodeOAuthCredentialImportError {
            switch error {
            case .missing, .malformed, .expired:
                break
            case .accessDenied:
                throw error
            }

            // Refuse to snapshot the global item unless it still belongs to the
            // account we just connected. This is what keeps a second
            // subscription from capturing the first account's token if logins
            // are interleaved.
            let expectedAccountDescription = normalizedCredentialDirectory(expectedAccountDescription)
            if let expectedAccountDescription,
               !defaultClaudeAccountMatches(expectedAccountDescription) {
                throw ClaudeCodeOAuthCredentialImportError.missing
            }

            credentials = try ClaudeCodeOAuthCredentialImporter()
                .captureDefaultKeychainCredential()
        }

        let service = ClaudeCodeOAuthCredentialImporter.profileScopedKeychainService(
            configDirectory: configDirectory
        )
        try KeychainStore(service: service, legacyServices: [])
            .set(credentials.routeCredentialStoragePayload(), for: NSUserName())
    }

    nonisolated private static func normalizedCredentialDirectory(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func defaultClaudeAccountMatches(_ expectedAccountDescription: String) -> Bool {
        let defaultAccount = CLIAuthDiscovery
            .discoverAuthState(for: .claude, configDirectoryOverride: nil)
            .accountDescription
        guard let normalizedDefaultAccount = normalizedCredentialDirectory(defaultAccount) else {
            return false
        }
        return normalizedDefaultAccount.caseInsensitiveCompare(expectedAccountDescription) == .orderedSame
    }
}
