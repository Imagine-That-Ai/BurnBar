import Foundation
import OpenBurnBarCore

/// Relay/transport routing decisions for the Hermes chat surface: which
/// `HermesConnectionRecord`s are usable Mac relay candidates, which relay
/// to suggest, which relay a send should prefer, and which endpoint URLs
/// the direct-HTTP transport accepts.
///
/// All decision bodies were moved verbatim from `HermesService`; the
/// service keeps thin forwarders so its existing API surface
/// (`service.relayConnections`, `service.suggestedRelayConnection`,
/// `HermesService.validatedEndpointURL`, `HermesService.isRelayConnectionFresh`)
/// stays unchanged for views and tests. The selector never mutates service
/// state — `HermesService` remains the coordinator that *acts* on these
/// decisions (`selectConnection`, discovery refreshes, user-facing error
/// copy).
///
/// The live connection catalog is threaded via `connectionsProvider` at
/// init so the selector always evaluates against the shared runtime store
/// the service proxies expose. Reads stay synchronous on the main actor,
/// so @Observable tracking flows through to SwiftUI exactly as it did when
/// these bodies were inline on the service.
@MainActor
final class HermesTransportSelector {
    private let connectionsProvider: () -> [HermesConnectionRecord]

    init(connectionsProvider: @escaping () -> [HermesConnectionRecord]) {
        self.connectionsProvider = connectionsProvider
    }

    // MARK: - Relay candidate selection

    var relayConnections: [HermesConnectionRecord] {
        connectionsProvider().filter { connection in
            connection.mode == .relayLink
                && connection.status == .online
                && Self.canAttemptRelayConnection(connection)
        }
    }

    var suggestedRelayConnection: HermesConnectionRecord? {
        relayConnections.sorted { lhs, rhs in
            let lhsFresh = Self.isRelayConnectionFresh(lhs)
            let rhsFresh = Self.isRelayConnectionFresh(rhs)
            if lhsFresh != rhsFresh {
                return lhsFresh
            }
            let lhsLastSeen = lhs.lastSeenAt ?? lhs.updatedAt
            let rhsLastSeen = rhs.lastSeenAt ?? rhs.updatedAt
            return lhsLastSeen > rhsLastSeen
        }.first
    }

    /// Pure decision core of `HermesService.preferredRelayConnection` —
    /// the optional discovery refresh that precedes it stays on the
    /// service.
    func preferredRelayConnection(selected: HermesConnectionRecord) -> HermesConnectionRecord? {
        if selected.mode == .relayLink,
           let selectedRelay = relayConnections.first(where: { $0.id == selected.id }) {
            return selectedRelay
        }
        if selected.mode == .relayLink,
           Self.canAttemptRelayConnection(selected) {
            return selected
        }

        return suggestedRelayConnection ?? relayConnections.first
    }

    // MARK: - Record-level eligibility predicates

    static func canAttemptRelayConnection(_ connection: HermesConnectionRecord) -> Bool {
        connection.mode == .relayLink
            && connection.status == .online
            && hasUsableRelayEncryption(connection)
            && isRelayConnectionFresh(connection)
    }

    static func hasUsableRelayEncryption(_ connection: HermesConnectionRecord) -> Bool {
        connection.relayEncryption == HermesRelayCrypto.relayEncryptionV3
            && connection.relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3
            && (connection.relayPublicKey?.isEmpty == false)
    }

    // macOS publishes this heartbeat every 30 s while active and every 5 min
    // in the background. Give background cadence, App Nap, and Firestore cache
    // propagation enough slack without accepting truly abandoned relay docs.
    nonisolated static let relayFreshnessWindow: TimeInterval = 30 * 60

    static func isRelayConnectionFresh(_ connection: HermesConnectionRecord, now: Date = Date()) -> Bool {
        guard connection.mode == .relayLink else { return true }
        let heartbeat = connection.realtimeRelayLastSeenAt
            ?? connection.lastSeenAt
            ?? connection.updatedAt
        return now.timeIntervalSince(heartbeat) <= relayFreshnessWindow
    }

    static func advertisesCLIModelCatalog(_ connection: HermesConnectionRecord) -> Bool {
        connection.capabilities.contains("cli_agent_model_catalog")
            || connection.capabilities.contains(HermesRelayOperation.cliAgentModelCatalog.rawValue)
    }

    // MARK: - Direct-HTTP endpoint validation

    static func validatedEndpointURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        if scheme == "https" {
            return url
        }
        if scheme == "http", host == "localhost" || host == "127.0.0.1" || Self.isPrivateIPv4(host) {
            return url
        }
        return nil
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }
}
