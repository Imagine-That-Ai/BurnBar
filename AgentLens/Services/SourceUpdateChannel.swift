import AppKit
import Foundation

#if !DISTRIBUTION_MAS

enum SourceUpdateChannelError: LocalizedError {
    case sourceRootUnavailable
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceRootUnavailable:
            return "This build is not linked to a local OpenBurnBar git checkout."
        case let .gitFailed(message):
            return message.isEmpty ? "Git could not determine source update status." : message
        }
    }
}

struct SourceUpdateChannel {
    static let manualUpdateCommand = "git pull --ff-only && ./scripts/build.sh"

    func fetchStatus() async throws -> SourceUpdateStatus {
        let sourceRoot = try sourceRootURL()
        try await runGit(["fetch", "--quiet", "--prune", "--no-tags", "origin"], in: sourceRoot)

        let currentSHA = try await runGit(["rev-parse", "HEAD"], in: sourceRoot)
        let upstream = try await trackedBranch(in: sourceRoot)
        let counts = try await runGit(["rev-list", "--left-right", "--count", "HEAD...\(upstream)"], in: sourceRoot)
        let parts = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        let behindBy = parts.count == 2 ? parts[1] : 0

        return SourceUpdateStatus(
            behindBy: behindBy,
            defaultBranch: upstream.replacingOccurrences(of: "origin/", with: ""),
            currentSHA: currentSHA,
            compareURL: try? await compareURL(upstream: upstream, currentSHA: currentSHA, in: sourceRoot) // try?-ok(compare link is optional UI metadata)
        )
    }

    func openManualUpdateInTerminal() {
        guard let sourceRoot = try? sourceRootURL() else { // try?-ok(fallback opens generic manual command when source root is unavailable)
            TerminalCommandRunner.open(command: Self.manualUpdateCommand)
            return
        }
        TerminalCommandRunner.open(command: command(in: sourceRoot))
    }

    func runOneClickUpdate(onFailure: @escaping @Sendable (String) -> Void) async {
        do {
            let sourceRoot = try sourceRootURL()
            TerminalCommandRunner.open(command: command(in: sourceRoot))
        } catch {
            onFailure(error.localizedDescription)
        }
    }

    private func trackedBranch(in sourceRoot: URL) async throws -> String {
        if let upstream = try? await runGit( // try?-ok(no upstream falls back to origin default branch)
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: sourceRoot
        ), !upstream.isEmpty {
            return upstream
        }
        if let defaultRef = try? await runGit(["symbolic-ref", "refs/remotes/origin/HEAD"], in: sourceRoot), // try?-ok(no origin HEAD falls back to origin/main)
           let branch = defaultRef.split(separator: "/").last {
            return "origin/\(branch)"
        }
        return "origin/main"
    }

    private func compareURL(upstream: String, currentSHA: String, in sourceRoot: URL) async throws -> URL? {
        let remoteURL = try await runGit(["config", "--get", "remote.origin.url"], in: sourceRoot)
        guard let (owner, repo) = parseGitHubRemote(remoteURL) else { return nil }
        let branch = upstream.replacingOccurrences(of: "origin/", with: "")
        return URL(string: "https://github.com/\(owner)/\(repo)/compare/\(currentSHA)...\(branch)")
    }

    private func command(in sourceRoot: URL) -> String {
        let path = sourceRoot.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "cd \"\(path)\" && \(Self.manualUpdateCommand)"
    }

    private func sourceRootURL() throws -> URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "OpenBurnBarSourceRoot") as? String,
           !path.isEmpty {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url
            }
        }

        var candidate = URL(fileURLWithPath: #filePath).standardizedFileURL
        while candidate.path != "/" {
            candidate.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
        }
        throw SourceUpdateChannelError.sourceRootUnavailable
    }

    @discardableResult
    private func runGit(_ arguments: [String], in sourceRoot: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = sourceRoot

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw SourceUpdateChannelError.gitFailed(error.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private func parseGitHubRemote(_ remoteURL: String) -> (String, String)? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("git@github.com:") {
            let path = trimmed.replacingOccurrences(of: "git@github.com:", with: "")
            return parseOwnerRepo(path)
        }
        if let url = URL(string: trimmed), url.host == "github.com" {
            return parseOwnerRepo(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return nil
    }

    private func parseOwnerRepo(_ path: String) -> (String, String)? {
        let components = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        return (components[0], components[1].replacingOccurrences(of: ".git", with: ""))
    }
}

#endif
