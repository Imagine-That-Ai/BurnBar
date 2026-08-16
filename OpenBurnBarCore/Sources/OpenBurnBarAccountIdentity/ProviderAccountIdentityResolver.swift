import Foundation
import OpenBurnBarKernel

/// The signed-in identity of a provider's local tool at a moment in time,
/// resolved from that tool's own on-disk state (never from OpenBurnBar
/// credentials).
///
/// `rawIdentity` is the stable identity string (an email or vendor account id).
/// It is used only to derive the anonymized `acct_sha256_…` usage partition
/// token and is never persisted verbatim into usage rows; `label` is the
/// human-readable seat name shown in per-account rollups.
public struct ResolvedProviderAccountIdentity: Equatable, Sendable {
    public let rawIdentity: String
    public let label: String
    public let scope: ProviderAccountStorageScope

    public init(rawIdentity: String, label: String, scope: ProviderAccountStorageScope) {
        self.rawIdentity = rawIdentity
        self.label = label
        self.scope = scope
    }
}

/// Resolves which provider account is currently signed in for one or more
/// providers by reading that tool's local, non-secret identity metadata.
///
/// Resolvers must be cheap (a small file or single-row SQLite read), must not
/// mutate the tool's state, and must never retain or log credential material —
/// only identity strings (emails, account ids) may leave the resolver.
public protocol ProviderAccountIdentityResolving: Sendable {
    /// Providers whose locally parsed usage this identity applies to.
    var providers: [AgentProvider] { get }
    func resolveCurrentIdentity() -> ResolvedProviderAccountIdentity?
}

extension [any ProviderAccountIdentityResolving] {
    /// The default resolver set for providers whose signed-in identity is
    /// locally discoverable. Providers without a resolver keep emitting
    /// unattributed usage, which downstream rollups already group as the
    /// provider's legacy/default lane.
    public static func defaultResolvers(environment: [String: String] = ProcessInfo.processInfo.environment) -> [any ProviderAccountIdentityResolving] {
        [
            CursorAccountIdentityResolver(),
            CodexAccountIdentityResolver(environment: environment),
            ClaudeAccountIdentityResolver(environment: environment)
        ]
    }
}
