import Foundation
import OpenBurnBarKernel

/// Resolves the Anthropic account currently signed in to Claude Code from the
/// `oauthAccount` block of `.claude.json` (settings/state, honoring
/// `CLAUDE_CONFIG_DIR`).
///
/// This reads account metadata only. It preserves OpenBurnBar's documented
/// Claude posture: no Keychain access and no `~/.claude/.credentials.json`
/// reads (see docs/PROVIDER_USAGE_DATA_REFERENCE.md §1.3).
public struct ClaudeAccountIdentityResolver: ProviderAccountIdentityResolving {
    public let providers: [AgentProvider] = [.claudeCode]

    private let configFileCandidates: [URL]
    private let fileManager: FileManager

    public init(
        configFileCandidates: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        if let configFileCandidates {
            self.configFileCandidates = configFileCandidates
        } else {
            var candidates: [URL] = []
            if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
                for dir in configDir.split(separator: ",") {
                    candidates.append(
                        URL(fileURLWithPath: (String(dir) as NSString).expandingTildeInPath)
                            .appendingPathComponent(".claude.json")
                    )
                }
            }
            candidates.append(
                URL(fileURLWithPath: ("~/.claude.json" as NSString).expandingTildeInPath)
            )
            self.configFileCandidates = candidates
        }
        self.fileManager = fileManager
    }

    public func resolveCurrentIdentity() -> ResolvedProviderAccountIdentity? {
        for candidate in configFileCandidates {
            guard fileManager.fileExists(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let account = object["oauthAccount"] as? [String: Any] else { continue }

            let accountUuid = (account["accountUuid"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let email = (account["emailAddress"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let rawIdentity = [accountUuid, email?.lowercased()]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            guard let rawIdentity else { continue }

            let label: String
            if let email, !email.isEmpty {
                label = email
            } else {
                label = "Claude \(String(rawIdentity.prefix(8)))…"
            }
            return ResolvedProviderAccountIdentity(
                rawIdentity: rawIdentity,
                label: label,
                scope: .localOnly
            )
        }
        return nil
    }
}
