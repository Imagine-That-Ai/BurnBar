import Foundation
import OpenBurnBarKernel

/// Resolves the OpenAI account currently signed in to the Codex CLI from
/// `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`).
///
/// The file holds OAuth tokens; this resolver extracts identity claims only —
/// `tokens.account_id` plus the `email` claim from the id-token payload — and
/// never retains, logs, or forwards token material. API-key-only installs
/// (no `tokens` object) resolve to `nil` and stay unattributed.
public struct CodexAccountIdentityResolver: ProviderAccountIdentityResolving {
    public let providers: [AgentProvider] = [.codex]

    private let authFileCandidates: [URL]
    private let fileManager: FileManager

    /// Auth files are small; anything larger is not the file we expect.
    private static let maxAuthFileBytes = 1 << 20

    public init(
        authFileCandidates: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        if let authFileCandidates {
            self.authFileCandidates = authFileCandidates
        } else {
            var candidates: [URL] = []
            if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
                candidates.append(
                    URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                        .appendingPathComponent("auth.json")
                )
            }
            candidates.append(
                URL(fileURLWithPath: ("~/.codex/auth.json" as NSString).expandingTildeInPath)
            )
            self.authFileCandidates = candidates
        }
        self.fileManager = fileManager
    }

    public func resolveCurrentIdentity() -> ResolvedProviderAccountIdentity? {
        for candidate in authFileCandidates {
            guard fileManager.fileExists(atPath: candidate.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  (attributes[.size] as? Int ?? 0) <= Self.maxAuthFileBytes,
                  let data = try? Data(contentsOf: candidate),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tokens = object["tokens"] as? [String: Any] else { continue }

            let accountID = (tokens["account_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let email = (tokens["id_token"] as? String)
                .flatMap(Self.identityClaims(fromJWT:))?
                .email?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let rawIdentity = [accountID, email?.lowercased()]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            guard let rawIdentity else { continue }

            let label: String
            if let email, !email.isEmpty {
                label = email
            } else {
                label = "OpenAI \(String(rawIdentity.prefix(8)))…"
            }
            return ResolvedProviderAccountIdentity(
                rawIdentity: rawIdentity,
                label: label,
                scope: .localOnly
            )
        }
        return nil
    }

    struct IdentityClaims {
        var email: String?
    }

    /// Decodes the JWT payload segment and returns identity claims only. The
    /// token is parsed in memory and nothing but the claim strings escape.
    static func identityClaims(fromJWT jwt: String) -> IdentityClaims? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let payloadData = Data(base64Encoded: base64),
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }
        return IdentityClaims(email: payload["email"] as? String)
    }
}
