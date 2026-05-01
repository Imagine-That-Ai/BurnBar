import AppKit
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
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    func reconnect(profile: SwitcherProfileRecord) async -> ReconnectResult {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType else {
            return .failed("Only Codex and Claude Code CLI profiles can reconnect.")
        }

        guard cliType == .codex || cliType == .claude else {
            return .failed("This CLI does not support account reconnect yet.")
        }

        guard let executablePath = CLILaunchAdapter.executablePath(for: cliType) else {
            return .failed("\(cliType.displayName) is not installed.")
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

        do {
            try dependencies.fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try writeScript(
                to: scriptURL,
                markerURL: markerURL,
                executablePath: executablePath,
                cliType: cliType,
                configDirectory: configDirectory,
                workingDirectory: profile.cliMetadata?.workingDirectory
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
            if terminationStatus != 0 {
                return .failed("\(cliType.displayName) login did not complete successfully.")
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
                updatedProfile: updatedProfile,
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
                isDisabled: existingMetadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )
    }

    private func writeScript(
        to scriptURL: URL,
        markerURL: URL,
        executablePath: String,
        cliType: SwitcherCLIProfileType,
        configDirectory: String,
        workingDirectory: String?
    ) throws {
        let commands = loginCommands(for: cliType, executablePath: executablePath)
        let configEnvKeys = configEnvironmentKeys(for: cliType)

        var lines: [String] = [
            "#!/bin/zsh",
            "set +e",
            "STATUS=1",
            "trap 'printf \"%s\" \"$STATUS\" > \(shellEscape(markerURL.path))' EXIT",
            "mkdir -p \(shellEscape(configDirectory))"
        ]

        if let workingDirectory = normalized(workingDirectory) {
            lines.append("cd \(shellEscape(workingDirectory)) || exit 1")
        }

        for configEnvKey in configEnvKeys {
            lines.append("export \(configEnvKey)=\(shellEscape(configDirectory))")
        }

        if let first = commands.first {
            lines.append(first)
            lines.append("STATUS=$?")
        }

        if commands.count > 1, let second = commands.dropFirst().first {
            lines.append("if [[ $STATUS -ne 0 && $STATUS -ne 130 && $STATUS -ne 143 ]]; then")
            lines.append("  \(second)")
            lines.append("  STATUS=$?")
            lines.append("fi")
        }

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
            return ["CLAUDE_CONFIG_PATH"]
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
}
