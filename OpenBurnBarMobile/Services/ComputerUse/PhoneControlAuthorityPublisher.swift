#if canImport(UIKit)
import CryptoKit
import Foundation
import LocalAuthentication
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay

/// Publishes the phone-control signing public key to Firestore before the
/// `control.input` stream is classified.
///
/// The Mac must not trust a public key carried inside the same stream that key
/// is meant to authenticate. This publisher anchors the key in the user's
/// trusted-device namespace under the active `iroh_pairing/{connectionId}` doc
/// so the Mac can fetch it independently by `authorityPeerNodeId`.
protocol PhoneControlAuthorityPublishing: Sendable {
    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws

    /// F2: key-kind-aware publish — uploads the canonical published bytes
    /// (32-byte raw Ed25519 / 65-byte X9.63 P-256) plus the `keyKind`
    /// discriminator the server persists as `signingKeyKind`.
    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKeyRepresentation: Data,
        keyKind: PhoneControlSigningKeyKind
    ) async throws
}

final class PhoneControlAuthorityPublisher: PhoneControlAuthorityPublishing, Sendable {
    static let shared = PhoneControlAuthorityPublisher()

    init() {}

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws {
        try await publish(
            uid: uid,
            connectionId: connectionId,
            deviceId: deviceId,
            peerNodeId: peerNodeId,
            publicKeyRepresentation: publicKey.rawRepresentation,
            keyKind: .ed25519
        )
    }

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKeyRepresentation: Data,
        keyKind: PhoneControlSigningKeyKind
    ) async throws {
        try await ComputerUseSecurityCallableClient.publishPhoneControlAuthority(
            expectedUID: uid,
            deviceId: deviceId,
            connectionId: connectionId,
            peerNodeId: peerNodeId,
            publicKeyBase64: publicKeyRepresentation.base64EncodedString(),
            publishedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            protocolVersion: HermesRealtimeRelayProtocol.version,
            keyKind: keyKind
        )
    }
}

enum IrohControllerRouteProofKind: String, Codable, Sendable, Equatable {
    case bootstrap
    case transportRenewal = "transport-renewal"
}

struct IrohControllerRouteChallenge: Codable, Sendable, Equatable {
    let challengeId: String
    let canonicalPayloadBase64: String
    let signatureAlgorithm: String
    let proofKind: IrohControllerRouteProofKind
    let registrationGeneration: Int64
    let issuedAtMillis: Int64
    let expiresAtMillis: Int64
}

struct IrohControllerRouteRegistration: Codable, Sendable, Equatable {
    let connectionId: String
    let sourceDeviceId: String
    let transportNodeId: String
    let authorityPeerNodeId: String
    let generation: Int64
    let expiresAtMillis: Int64
}

protocol IrohControllerRouteCallableGateway: Sendable {
    func issueChallenge(
        expectedUID: String,
        sourceDeviceId: String,
        connectionId: String,
        authorityPeerNodeId: String,
        transportNodeId: String
    ) async throws -> IrohControllerRouteChallenge

    func register(
        expectedUID: String,
        challengeId: String,
        transportSignatureBase64: String,
        authoritySignatureBase64: String?
    ) async throws -> IrohControllerRouteRegistration

    func revoke(
        expectedUID: String,
        sourceDeviceId: String,
        connectionId: String
    ) async throws
}

struct LiveIrohControllerRouteCallableGateway: IrohControllerRouteCallableGateway {
    func issueChallenge(
        expectedUID: String,
        sourceDeviceId: String,
        connectionId: String,
        authorityPeerNodeId: String,
        transportNodeId: String
    ) async throws -> IrohControllerRouteChallenge {
        try await ComputerUseSecurityCallableClient.issueIrohControllerRouteChallenge(
            expectedUID: expectedUID,
            sourceDeviceId: sourceDeviceId,
            connectionId: connectionId,
            authorityPeerNodeId: authorityPeerNodeId,
            transportNodeId: transportNodeId
        )
    }

    func register(
        expectedUID: String,
        challengeId: String,
        transportSignatureBase64: String,
        authoritySignatureBase64: String?
    ) async throws -> IrohControllerRouteRegistration {
        try await ComputerUseSecurityCallableClient.registerIrohControllerRoute(
            expectedUID: expectedUID,
            challengeId: challengeId,
            transportSignatureBase64: transportSignatureBase64,
            authoritySignatureBase64: authoritySignatureBase64
        )
    }

    func revoke(
        expectedUID: String,
        sourceDeviceId: String,
        connectionId: String
    ) async throws {
        try await ComputerUseSecurityCallableClient.revokeIrohControllerRoute(
            expectedUID: expectedUID,
            sourceDeviceId: sourceDeviceId,
            connectionId: connectionId
        )
    }
}

protocol IrohControllerRouteLifecycleManaging: Sendable {
    func invalidateAndRevoke() async

    func invalidateForAccountChange() async
}

protocol IrohControllerRouteAuthLifecycleManaging: Sendable {
    func tearDownAndRevoke() async
}

protocol IrohControllerRouteRegistering: IrohControllerRouteLifecycleManaging {
    @discardableResult
    func registerIfNeeded(
        uid: String,
        connectionId: String,
        sourceDeviceId: String,
        transportIdentity: IrohEndpointIdentity
    ) async throws -> IrohControllerRouteRegistration

}

enum IrohControllerRouteRegistrarError: LocalizedError, Equatable {
    case invalidTransportSecret
    case transportIdentityKeyMismatch
    case unsupportedSignatureAlgorithm(String)
    case invalidCanonicalPayload
    case invalidRegistrationResponse
    case backgroundRenewalRequiresBootstrap
    case routeSuperseded
    case authorityAuthenticationUnavailable
    case authorityAuthenticationCancelled
    case authorityAuthenticationFailed
    case authorityIdentityChanged

    var errorDescription: String? {
        switch self {
        case .invalidTransportSecret:
            return "The persisted iroh transport identity is unavailable."
        case .transportIdentityKeyMismatch:
            return "The persisted iroh signing key does not match the active transport endpoint."
        case .unsupportedSignatureAlgorithm(let algorithm):
            return "The controller-route challenge requested unsupported signature algorithm \(algorithm)."
        case .invalidCanonicalPayload:
            return "The controller-route challenge payload is not canonical base64."
        case .invalidRegistrationResponse:
            return "The controller-route registration response did not match the requested route."
        case .backgroundRenewalRequiresBootstrap:
            return "A background controller-route renewal unexpectedly required an authority bootstrap proof."
        case .routeSuperseded:
            return "The iroh endpoint identity changed while its controller route was registering."
        case .authorityAuthenticationUnavailable:
            return "Device authentication is unavailable. Enable Touch ID or Face ID, then try Mercury again."
        case .authorityAuthenticationCancelled:
            return "Mercury connection authentication was cancelled."
        case .authorityAuthenticationFailed:
            return "Mercury could not authenticate this device. Try again and approve the biometric prompt."
        case .authorityIdentityChanged:
            return "The phone-control security identity changed during Mercury setup. Try connecting again."
        }
    }
}

private enum IrohControllerRouteAuthorityAuthenticator {
    private static let reason = "Authenticate to connect Mercury securely to this Mac."

    static func authenticatedIdentity(
        matching identity: PhoneControlAuthoritySigningKey
    ) async throws -> PhoneControlAuthoritySigningKey {
        #if DEBUG
        NSLog("OpenBurnBarMercury controller_route_auth_identity kind=\(identity.kind.rawValue)")
        #endif
        guard identity.kind == .secureEnclaveP256 else {
            return identity
        }

        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &policyError
        ) else {
            #if DEBUG
            NSLog(
                "OpenBurnBarMercury controller_route_auth_unavailable error=\(policyError?.localizedDescription ?? "unknown")"
            )
            #endif
            throw IrohControllerRouteRegistrarError.authorityAuthenticationUnavailable
        }

        #if DEBUG
        NSLog("OpenBurnBarMercury controller_route_auth_evaluate_start")
        #endif
        do {
            try await withCheckedThrowingContinuation { continuation in
                context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                ) { success, error in
                    #if DEBUG
                    NSLog(
                        "OpenBurnBarMercury controller_route_auth_evaluate_complete success=\(success) error=\(error?.localizedDescription ?? "none")"
                    )
                    #endif
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: error ?? LAError(.authenticationFailed)
                        )
                    }
                }
            }
        } catch let error as LAError {
            switch error.code {
            case .appCancel, .systemCancel, .userCancel:
                throw IrohControllerRouteRegistrarError.authorityAuthenticationCancelled
            default:
                throw IrohControllerRouteRegistrarError.authorityAuthenticationFailed
            }
        } catch {
            throw IrohControllerRouteRegistrarError.authorityAuthenticationFailed
        }

        let authenticatedIdentity: PhoneControlAuthoritySigningKey
        do {
            #if DEBUG
            NSLog("OpenBurnBarMercury controller_route_auth_reload_start")
            #endif
            authenticatedIdentity = try PhoneControlSigningKeyStore.shared.signingIdentity(
                authenticationContext: context
            )
            #if DEBUG
            NSLog("OpenBurnBarMercury controller_route_auth_reload_complete")
            #endif
        } catch {
            #if DEBUG
            NSLog(
                "OpenBurnBarMercury controller_route_auth_reload_failed error=\(error.localizedDescription)"
            )
            #endif
            throw IrohControllerRouteRegistrarError.authorityAuthenticationFailed
        }
        guard authenticatedIdentity.kind == identity.kind,
              authenticatedIdentity.publicKeyRepresentation == identity.publicKeyRepresentation else {
            throw IrohControllerRouteRegistrarError.authorityIdentityChanged
        }
        return authenticatedIdentity
    }
}

enum IrohControllerRouteProofParser {
    private static let domain = Data("OpenBurnBar-IrohControllerRoute-v2\n".utf8)
    private static let maximumPayloadBytes = 16 * 1_024
    private static let orderedFieldNames = [
        "version",
        "challengeId",
        "challengeNonce",
        "proofKind",
        "uid",
        "connectionId",
        "sourceDeviceId",
        "transportNodeId",
        "authorityPeerNodeId",
        "registrationGeneration",
        "issuedAtMillis",
        "expiresAtMillis"
    ]

    static func validate(
        _ payload: Data,
        challenge: IrohControllerRouteChallenge,
        uid: String,
        connectionId: String,
        sourceDeviceId: String,
        transportNodeId: String,
        authorityPeerNodeId: String
    ) throws {
        guard payload.count <= maximumPayloadBytes,
              payload.starts(with: domain) else {
            throw IrohControllerRouteRegistrarError.invalidCanonicalPayload
        }
        var cursor = domain.count
        var fields: [String: String] = [:]
        for expectedName in orderedFieldNames {
            let name = try readFrame(payload, cursor: &cursor)
            guard name == expectedName else {
                throw IrohControllerRouteRegistrarError.invalidCanonicalPayload
            }
            fields[name] = try readFrame(payload, cursor: &cursor)
        }
        guard cursor == payload.count,
              fields.count == orderedFieldNames.count,
              fields["version"] == "2",
              fields["challengeId"] == challenge.challengeId,
              isCanonicalNonce(fields["challengeNonce"]),
              fields["proofKind"] == challenge.proofKind.rawValue,
              fields["uid"] == uid,
              fields["connectionId"] == connectionId,
              fields["sourceDeviceId"] == sourceDeviceId,
              fields["transportNodeId"] == transportNodeId,
              fields["authorityPeerNodeId"] == authorityPeerNodeId,
              canonicalPositiveInt64(fields["registrationGeneration"]) == challenge.registrationGeneration,
              canonicalPositiveInt64(fields["issuedAtMillis"]) == challenge.issuedAtMillis,
              canonicalPositiveInt64(fields["expiresAtMillis"]) == challenge.expiresAtMillis,
              challenge.expiresAtMillis > challenge.issuedAtMillis else {
            throw IrohControllerRouteRegistrarError.invalidCanonicalPayload
        }
    }

    private static func readFrame(_ payload: Data, cursor: inout Int) throws -> String {
        let lengthStart = cursor
        while cursor < payload.count, payload[cursor] >= 0x30, payload[cursor] <= 0x39 {
            cursor += 1
        }
        guard cursor > lengthStart,
              cursor < payload.count,
              payload[cursor] == 0x3a,
              !(cursor - lengthStart > 1 && payload[lengthStart] == 0x30),
              let lengthText = String(data: payload[lengthStart..<cursor], encoding: .utf8),
              let byteCount = Int(lengthText),
              byteCount >= 0 else {
            throw IrohControllerRouteRegistrarError.invalidCanonicalPayload
        }
        cursor += 1
        guard byteCount <= payload.count - cursor - 1 else {
            throw IrohControllerRouteRegistrarError.invalidCanonicalPayload
        }
        let valueEnd = cursor + byteCount
        guard payload[valueEnd] == 0x0a,
              let value = String(data: payload[cursor..<valueEnd], encoding: .utf8) else {
            throw IrohControllerRouteRegistrarError.invalidCanonicalPayload
        }
        cursor = valueEnd + 1
        return value
    }

    private static func canonicalPositiveInt64(_ raw: String?) -> Int64? {
        guard let raw,
              let value = Int64(raw),
              value > 0,
              String(value) == raw else { return nil }
        return value
    }

    private static func isCanonicalNonce(_ raw: String?) -> Bool {
        guard let raw,
              !raw.isEmpty,
              raw.utf8.count <= 128 else { return false }
        return raw.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5a)
                || (byte >= 0x61 && byte <= 0x7a)
                || byte == 0x2d
                || byte == 0x5f
        }
    }
}

actor IrohControllerRouteAuthLifecycleCoordinator: IrohControllerRouteAuthLifecycleManaging {
    static let shared = IrohControllerRouteAuthLifecycleCoordinator()

    private struct LifecycleTail: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let routeLifecycle: any IrohControllerRouteLifecycleManaging
    private let endpointTeardown: @Sendable () async -> Void
    private var hasObservedAuthState = false
    private var authenticatedUID: String?
    private var lifecycleTail: LifecycleTail?

    init(
        routeLifecycle: any IrohControllerRouteLifecycleManaging = IrohControllerRouteRegistrar.shared,
        endpointTeardown: @escaping @Sendable () async -> Void = {
            await HermesIrohRelayTransport.shared.tearDownForAuthTransition()
        }
    ) {
        self.routeLifecycle = routeLifecycle
        self.endpointTeardown = endpointTeardown
    }

    func handleAuthenticatedUIDChanged(to uid: String?) async {
        let priorUID = authenticatedUID
        let hadObservedAuthState = hasObservedAuthState
        hasObservedAuthState = true
        authenticatedUID = uid
        guard hadObservedAuthState, uid != priorUID else { return }
        await enqueueLifecycleOperation { [endpointTeardown, routeLifecycle] in
            await endpointTeardown()
            // Firebase has already changed credentials when its listener fires.
            // Never issue an old-account revoke under the replacement account.
            await routeLifecycle.invalidateForAccountChange()
        }
    }

    func tearDownAndRevoke() async {
        await enqueueLifecycleOperation { [endpointTeardown, routeLifecycle] in
            await endpointTeardown()
            // Explicit sign-out/delete still owns the old Firebase credential,
            // so durable revocation must finish before auth is cleared.
            await routeLifecycle.invalidateAndRevoke()
        }
    }

    private func enqueueLifecycleOperation(
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        let predecessor = lifecycleTail?.task
        let task = Task {
            if let predecessor {
                await predecessor.value
            }
            await operation()
        }
        let id = UUID()
        lifecycleTail = LifecycleTail(id: id, task: task)
        await task.value
        if lifecycleTail?.id == id {
            lifecycleTail = nil
        }
    }
}

/// Establishes the server-issued mapping from the app's controller authority
/// identity to the separate QUIC transport identity before any iroh dial.
actor IrohControllerRouteRegistrar: IrohControllerRouteRegistering {
    static let shared = IrohControllerRouteRegistrar()

    private struct RouteKey: Hashable, Sendable {
        let uid: String
        let connectionId: String
        let sourceDeviceId: String
        let transportNodeId: String
        let authorityPeerNodeId: String
    }

    private struct RouteScope: Hashable, Sendable {
        let uid: String
        let connectionId: String
        let sourceDeviceId: String
    }

    private struct RenewalContext: Sendable {
        let uid: String
        let connectionId: String
        let sourceDeviceId: String
        let transportIdentity: IrohEndpointIdentity
    }

    private struct CachedRegistration: Sendable {
        let registration: IrohControllerRouteRegistration
    }

    private struct ScopeTail: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static let defaultRenewalLeadMillis: Int64 = 120_000
    private static let maximumAcceptedLeaseDurationMillis: Int64 = 15 * 60 * 1_000

    private let gateway: any IrohControllerRouteCallableGateway
    private let authorityPublisher: any PhoneControlAuthorityPublishing
    private let transportSecretProvider: @Sendable () throws -> Data
    private let authorityIdentityProvider: @Sendable () throws -> PhoneControlAuthoritySigningKey
    private let authorityBootstrapIdentityProvider:
        @Sendable (PhoneControlAuthoritySigningKey) async throws -> PhoneControlAuthoritySigningKey
    private let authorityPeerNodeIdProvider: @Sendable (PhoneControlAuthoritySigningKey) -> String
    private let authenticatedUIDProvider: @Sendable () -> String?
    private let nowMillis: @Sendable () -> Int64
    private let sleepMillis: @Sendable (Int64) async throws -> Void
    private let renewalLeadMillis: Int64
    private var cached: [RouteKey: CachedRegistration] = [:]
    private var inFlight: [RouteKey: Task<IrohControllerRouteRegistration, Error>] = [:]
    private var activeKeyByScope: [RouteScope: RouteKey] = [:]
    private var renewalTasks: [RouteKey: Task<Void, Never>] = [:]
    private var scopeTails: [RouteScope: ScopeTail] = [:]
    private var invalidationDepth = 0

    init(
        gateway: any IrohControllerRouteCallableGateway = LiveIrohControllerRouteCallableGateway(),
        authorityPublisher: any PhoneControlAuthorityPublishing = PhoneControlAuthorityPublisher.shared,
        transportSecretProvider: @escaping @Sendable () throws -> Data = {
            try IrohRelayKeyStore.shared.secretKeyMaterial().raw
        },
        authorityIdentityProvider: @escaping @Sendable () throws -> PhoneControlAuthoritySigningKey = {
            try PhoneControlSigningKeyStore.shared.signingIdentity()
        },
        authorityBootstrapIdentityProvider: @escaping @Sendable (
            PhoneControlAuthoritySigningKey
        ) async throws -> PhoneControlAuthoritySigningKey = {
            try await IrohControllerRouteAuthorityAuthenticator.authenticatedIdentity(matching: $0)
        },
        authorityPeerNodeIdProvider: @escaping @Sendable (PhoneControlAuthoritySigningKey) -> String = {
            PhoneControlSigningKeyStore.shared.peerNodeId(for: $0)
        },
        authenticatedUIDProvider: @escaping @Sendable () -> String? = {
            ComputerUseSecurityCallableClient.authenticatedUID
        },
        nowMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        sleepMillis: @escaping @Sendable (Int64) async throws -> Void = { milliseconds in
            let boundedMilliseconds = min(max(0, milliseconds), 24 * 60 * 60 * 1_000)
            try await Task.sleep(nanoseconds: UInt64(boundedMilliseconds) * 1_000_000)
        },
        renewalLeadMillis: Int64 = IrohControllerRouteRegistrar.defaultRenewalLeadMillis
    ) {
        self.gateway = gateway
        self.authorityPublisher = authorityPublisher
        self.transportSecretProvider = transportSecretProvider
        self.authorityIdentityProvider = authorityIdentityProvider
        self.authorityBootstrapIdentityProvider = authorityBootstrapIdentityProvider
        self.authorityPeerNodeIdProvider = authorityPeerNodeIdProvider
        self.authenticatedUIDProvider = authenticatedUIDProvider
        self.nowMillis = nowMillis
        self.sleepMillis = sleepMillis
        self.renewalLeadMillis = max(0, renewalLeadMillis)
    }

    @discardableResult
    func registerIfNeeded(
        uid: String,
        connectionId: String,
        sourceDeviceId: String,
        transportIdentity: IrohEndpointIdentity
    ) async throws -> IrohControllerRouteRegistration {
        try await registerIfNeeded(
            uid: uid,
            connectionId: connectionId,
            sourceDeviceId: sourceDeviceId,
            transportIdentity: transportIdentity,
            allowsAuthorityBootstrap: true
        )
    }

    private func registerIfNeeded(
        uid: String,
        connectionId: String,
        sourceDeviceId: String,
        transportIdentity: IrohEndpointIdentity,
        allowsAuthorityBootstrap: Bool
    ) async throws -> IrohControllerRouteRegistration {
        guard invalidationDepth == 0, authenticatedUIDProvider() == uid else {
            throw IrohControllerRouteRegistrarError.routeSuperseded
        }
        let authorityIdentity = try authorityIdentityProvider()
        let authorityPeerNodeId = authorityPeerNodeIdProvider(authorityIdentity)
        let key = RouteKey(
            uid: uid,
            connectionId: connectionId,
            sourceDeviceId: sourceDeviceId,
            transportNodeId: transportIdentity.nodeId,
            authorityPeerNodeId: authorityPeerNodeId
        )
        let scope = RouteScope(uid: uid, connectionId: connectionId, sourceDeviceId: sourceDeviceId)
        if let priorKey = activeKeyByScope[scope], priorKey != key {
            renewalTasks.removeValue(forKey: priorKey)?.cancel()
            cached[priorKey] = nil
        }
        activeKeyByScope[scope] = key
        let currentMillis = nowMillis()
        if let cached = cached[key],
           cached.registration.expiresAtMillis > currentMillis + renewalLeadMillis {
            return cached.registration
        }
        if let task = inFlight[key] {
            let registration = try await task.value
            guard activeKeyByScope[scope] == key else {
                throw IrohControllerRouteRegistrarError.routeSuperseded
            }
            return registration
        }

        let predecessor = scopeTails[scope]?.task
        let task = Task { [weak self] in
            if let predecessor {
                await predecessor.value
            }
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            return try await self.performRegistration(
                key: key,
                scope: scope,
                transportIdentity: transportIdentity,
                authorityIdentity: authorityIdentity,
                allowsAuthorityBootstrap: allowsAuthorityBootstrap
            )
        }
        let tailID = UUID()
        let tailTask = Task {
            _ = try? await task.value
        }
        scopeTails[scope] = ScopeTail(id: tailID, task: tailTask)
        inFlight[key] = task
        do {
            let registration = try await task.value
            inFlight[key] = nil
            clearScopeTail(scope: scope, id: tailID)
            guard activeKeyByScope[scope] == key else {
                cached[key] = nil
                throw IrohControllerRouteRegistrarError.routeSuperseded
            }
            cached[key] = CachedRegistration(registration: registration)
            scheduleRenewal(
                key: key,
                scope: scope,
                context: RenewalContext(
                    uid: uid,
                    connectionId: connectionId,
                    sourceDeviceId: sourceDeviceId,
                    transportIdentity: transportIdentity
                ),
                registration: registration
            )
            return registration
        } catch {
            inFlight[key] = nil
            clearScopeTail(scope: scope, id: tailID)
            cached[key] = nil
            throw error
        }
    }

    func invalidateAndRevoke() async {
        invalidationDepth += 1
        defer { invalidationDepth -= 1 }
        let scopes = Set(activeKeyByScope.keys)
        invalidateLocalState(cancelInFlight: false)
        for scope in scopes {
            if let tail = scopeTails[scope]?.task {
                await tail.value
            }
            do {
                try await gateway.revoke(
                    expectedUID: scope.uid,
                    sourceDeviceId: scope.sourceDeviceId,
                    connectionId: scope.connectionId
                )
            } catch {
                #if DEBUG
                NSLog(
                    "OpenBurnBar iroh_controller_route_revoke_failed connection=%@ error=%@",
                    scope.connectionId,
                    error.localizedDescription
                )
                #endif
            }
            scopeTails[scope] = nil
        }
        inFlight.removeAll()
    }

    func invalidateForAccountChange() async {
        invalidateLocalState(cancelInFlight: true)
    }

    func invalidateAll() {
        invalidateLocalState(cancelInFlight: true)
    }

    #if DEBUG
    func activeTransportNodeIdForTesting(
        uid: String,
        connectionId: String,
        sourceDeviceId: String
    ) -> String? {
        activeKeyByScope[
            RouteScope(
                uid: uid,
                connectionId: connectionId,
                sourceDeviceId: sourceDeviceId
            )
        ]?.transportNodeId
    }
    #endif

    private func invalidateLocalState(cancelInFlight: Bool) {
        renewalTasks.values.forEach { $0.cancel() }
        renewalTasks.removeAll()
        if cancelInFlight {
            inFlight.values.forEach { $0.cancel() }
            inFlight.removeAll()
            scopeTails.values.forEach { $0.task.cancel() }
            scopeTails.removeAll()
        }
        cached.removeAll()
        activeKeyByScope.removeAll()
    }

    private func clearScopeTail(scope: RouteScope, id: UUID) {
        guard scopeTails[scope]?.id == id else { return }
        scopeTails[scope] = nil
    }

    private func scheduleRenewal(
        key: RouteKey,
        scope: RouteScope,
        context: RenewalContext,
        registration: IrohControllerRouteRegistration,
        delayOverrideMillis: Int64? = nil,
        allowMissingCachedRegistration: Bool = false
    ) {
        renewalTasks.removeValue(forKey: key)?.cancel()
        let delayMillis = delayOverrideMillis ?? max(
            0,
            registration.expiresAtMillis - nowMillis() - renewalLeadMillis
        )
        let sleepMillis = self.sleepMillis
        let task = Task { [weak self] in
            do {
                try await sleepMillis(delayMillis)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledRenewal(
                key: key,
                scope: scope,
                context: context,
                priorRegistration: registration,
                allowMissingCachedRegistration: allowMissingCachedRegistration
            )
        }
        renewalTasks[key] = task
    }

    private func runScheduledRenewal(
        key: RouteKey,
        scope: RouteScope,
        context: RenewalContext,
        priorRegistration: IrohControllerRouteRegistration,
        allowMissingCachedRegistration: Bool
    ) async {
        guard activeKeyByScope[scope] == key else { return }
        if let current = cached[key] {
            guard current.registration.generation == priorRegistration.generation else { return }
        } else if !allowMissingCachedRegistration {
            return
        }
        renewalTasks[key] = nil
        cached[key] = nil
        do {
            _ = try await registerIfNeeded(
                uid: context.uid,
                connectionId: context.connectionId,
                sourceDeviceId: context.sourceDeviceId,
                transportIdentity: context.transportIdentity,
                allowsAuthorityBootstrap: false
            )
        } catch {
            guard activeKeyByScope[scope] == key else { return }
            cached[key] = nil
            let remainingMillis = priorRegistration.expiresAtMillis - nowMillis()
            guard remainingMillis > 1_000 else { return }
            scheduleRenewal(
                key: key,
                scope: scope,
                context: context,
                registration: priorRegistration,
                delayOverrideMillis: min(15_000, max(1_000, remainingMillis - 1_000)),
                allowMissingCachedRegistration: true
            )
        }
    }

    private func performRegistration(
        key: RouteKey,
        scope: RouteScope,
        transportIdentity: IrohEndpointIdentity,
        authorityIdentity: PhoneControlAuthoritySigningKey,
        allowsAuthorityBootstrap: Bool
    ) async throws -> IrohControllerRouteRegistration {
        try requireActiveOwnership(key: key, scope: scope)
        let secret = try transportSecretProvider()
        guard secret.count == 32,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else {
            throw IrohControllerRouteRegistrarError.invalidTransportSecret
        }
        guard signingKey.publicKey.rawRepresentation == transportIdentity.rawPublicKey else {
            throw IrohControllerRouteRegistrarError.transportIdentityKeyMismatch
        }
        let expectedTransportNodeId = transportIdentity.rawPublicKey.map {
            String(format: "%02x", $0)
        }.joined()
        try requireActiveOwnership(key: key, scope: scope)

        #if DEBUG
        NSLog("OpenBurnBarMercury controller_route_authority_publish_start connectionID=\(key.connectionId)")
        #endif
        try await authorityPublisher.publish(
            uid: key.uid,
            connectionId: key.connectionId,
            deviceId: key.sourceDeviceId,
            peerNodeId: key.authorityPeerNodeId,
            publicKeyRepresentation: authorityIdentity.publicKeyRepresentation,
            keyKind: authorityIdentity.kind
        )
        #if DEBUG
        NSLog("OpenBurnBarMercury controller_route_authority_publish_complete connectionID=\(key.connectionId)")
        #endif
        try requireActiveOwnership(key: key, scope: scope)
        #if DEBUG
        NSLog("OpenBurnBarMercury controller_route_challenge_start connectionID=\(key.connectionId)")
        #endif
        let challenge = try await gateway.issueChallenge(
            expectedUID: key.uid,
            sourceDeviceId: key.sourceDeviceId,
            connectionId: key.connectionId,
            authorityPeerNodeId: key.authorityPeerNodeId,
            transportNodeId: key.transportNodeId
        )
        #if DEBUG
        NSLog("OpenBurnBarMercury controller_route_challenge_complete connectionID=\(key.connectionId) proofKind=\(challenge.proofKind.rawValue)")
        #endif
        try requireActiveOwnership(key: key, scope: scope)
        guard challenge.signatureAlgorithm == "ed25519" else {
            throw IrohControllerRouteRegistrarError.unsupportedSignatureAlgorithm(challenge.signatureAlgorithm)
        }
        guard let payload = Data(base64Encoded: challenge.canonicalPayloadBase64),
              payload.base64EncodedString() == challenge.canonicalPayloadBase64 else {
            throw IrohControllerRouteRegistrarError.invalidCanonicalPayload
        }
        try IrohControllerRouteProofParser.validate(
            payload,
            challenge: challenge,
            uid: key.uid,
            connectionId: key.connectionId,
            sourceDeviceId: key.sourceDeviceId,
            transportNodeId: expectedTransportNodeId,
            authorityPeerNodeId: key.authorityPeerNodeId
        )
        guard challenge.expiresAtMillis > nowMillis() else {
            throw IrohControllerRouteRegistrarError.invalidCanonicalPayload
        }
        try requireActiveOwnership(key: key, scope: scope)
        let transportSignature = try signingKey.signature(for: payload).base64EncodedString()
        let authoritySignature: String?
        switch challenge.proofKind {
        case .bootstrap:
            guard allowsAuthorityBootstrap else {
                throw IrohControllerRouteRegistrarError.backgroundRenewalRequiresBootstrap
            }
            #if DEBUG
            NSLog(
                "OpenBurnBarMercury controller_route_bootstrap_sign_start connectionID=\(key.connectionId) authorityKind=\(authorityIdentity.kind.rawValue)"
            )
            #endif
            if authorityIdentity.kind == .secureEnclaveP256 {
                let authenticatedIdentity = try await authorityBootstrapIdentityProvider(
                    authorityIdentity
                )
                guard authenticatedIdentity.kind == authorityIdentity.kind,
                      authenticatedIdentity.publicKeyRepresentation
                        == authorityIdentity.publicKeyRepresentation,
                      authorityPeerNodeIdProvider(authenticatedIdentity)
                        == key.authorityPeerNodeId else {
                    throw IrohControllerRouteRegistrarError.authorityIdentityChanged
                }
                authoritySignature = try authenticatedIdentity.signatureBase64(for: payload)
            } else {
                authoritySignature = try authorityIdentity.signatureBase64(for: payload)
            }
            #if DEBUG
            NSLog("OpenBurnBarMercury controller_route_bootstrap_sign_complete connectionID=\(key.connectionId)")
            #endif
        case .transportRenewal:
            authoritySignature = nil
        }
        try requireActiveOwnership(key: key, scope: scope)
        #if DEBUG
        NSLog("OpenBurnBarMercury controller_route_register_start connectionID=\(key.connectionId)")
        #endif
        let registration = try await gateway.register(
            expectedUID: key.uid,
            challengeId: challenge.challengeId,
            transportSignatureBase64: transportSignature,
            authoritySignatureBase64: authoritySignature
        )
        #if DEBUG
        NSLog("OpenBurnBarMercury controller_route_register_complete connectionID=\(key.connectionId) generation=\(registration.generation)")
        #endif
        try requireActiveOwnership(key: key, scope: scope)
        let completionMillis = nowMillis()
        guard registration.connectionId == key.connectionId,
              registration.sourceDeviceId == key.sourceDeviceId,
              registration.transportNodeId == expectedTransportNodeId,
              registration.authorityPeerNodeId == key.authorityPeerNodeId,
              registration.generation == challenge.registrationGeneration,
              registration.expiresAtMillis > completionMillis,
              registration.expiresAtMillis <= completionMillis + Self.maximumAcceptedLeaseDurationMillis else {
            throw IrohControllerRouteRegistrarError.invalidRegistrationResponse
        }
        return registration
    }

    private func requireActiveOwnership(key: RouteKey, scope: RouteScope) throws {
        guard invalidationDepth == 0,
              authenticatedUIDProvider() == key.uid,
              activeKeyByScope[scope] == key else {
            throw IrohControllerRouteRegistrarError.routeSuperseded
        }
    }
}
#endif
