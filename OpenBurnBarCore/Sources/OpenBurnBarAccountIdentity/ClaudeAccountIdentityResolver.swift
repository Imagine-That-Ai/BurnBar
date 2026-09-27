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
                  let account = (try? JSONDecoder().decode(ClaudeConfigFile.self, from: data))?.oauthAccount
            else { continue }

            let accountUuid = account.accountUuid?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let email = account.emailAddress?.value?
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

/// Typed projection of `.claude.json`: only the non-secret `oauthAccount`
/// identity fields are decoded; everything else in the file is ignored.
private struct ClaudeConfigFile: Decodable {
    struct OAuthAccount: Decodable {
        let accountUuid: LenientJSONString?
        let emailAddress: LenientJSONString?
    }

    let oauthAccount: OAuthAccount?
}
