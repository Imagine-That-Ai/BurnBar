import XCTest
import CryptoKit
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OpenBurnBarIrohRelay
@testable import OpenBurnBarMobile
final class IrohControllerRouteRegistrarTests: XCTestCase {
    func testProofKindWireValuesAreClosedAndExact() {
        XCTAssertEqual(IrohControllerRouteProofKind(rawValue: "bootstrap"), .bootstrap)
        XCTAssertEqual(IrohControllerRouteProofKind(rawValue: "transport-renewal"), .transportRenewal)
        XCTAssertNil(IrohControllerRouteProofKind(rawValue: "authority-renewal"))
    }

    func testStrictPositiveInt64DecoderRejectsBooleanFractionAndOverflow() {
        XCTAssertNil(ComputerUseSecurityCallableClient.positiveInt64(true))
        XCTAssertNil(ComputerUseSecurityCallableClient.positiveInt64(1.5))
        XCTAssertNil(ComputerUseSecurityCallableClient.positiveInt64(0))
        XCTAssertNil(ComputerUseSecurityCallableClient.positiveInt64(
            NSNumber(value: Double(Int64.max))
        ))
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.positiveInt64(NSNumber(value: 42.0)),
            42
        )
    }

    func testRejectsMalformedCanonicalProofBeforeEitherKeySigns() async throws {
        let mutations: [(String, @Sendable (Data) -> Data)] = [
            ("malformed framing", IrohRouteProofMutation.malformedFraming),
            ("invalid UTF-8", IrohRouteProofMutation.invalidUTF8),
            ("extra field", IrohRouteProofMutation.extraField),
            ("missing field", IrohRouteProofMutation.missingField),
            ("wrong proof kind", IrohRouteProofMutation.wrongProofKind),
            ("wrong bound field", IrohRouteProofMutation.wrongUID)
        ]

        for (name, mutation) in mutations {
            let transportKey = Curve25519.Signing.PrivateKey()
            let gateway = IrohRouteFakeGateway(
                registrationExpiries: [20_000],
                canonicalPayloadTransform: mutation
            )
            let registrar = makeRegistrar(
                gateway: gateway,
                publisher: IrohRouteFakeAuthorityPublisher(),
                transportKey: transportKey,
                authorityKey: Curve25519.Signing.PrivateKey(),
                nowMillis: { 10_000 }
            )

            do {
                _ = try await registrar.registerIfNeeded(
                    uid: "user-1",
                    connectionId: "connection-1",
                    sourceDeviceId: "device-1",
                    transportIdentity: identity(for: transportKey)
                )
                XCTFail("Expected \(name) to fail before signing")
            } catch {
                XCTAssertEqual(
                    error as? IrohControllerRouteRegistrarError,
                    .invalidCanonicalPayload,
                    name
                )
            }
            let signatures = await gateway.recordedSignatures()
            let registerCalls = await gateway.registerCallCount()
            XCTAssertTrue(signatures.isEmpty, name)
            XCTAssertEqual(registerCalls, 0, name)
            await registrar.invalidateAll()
        }
    }

    func testRejectsExpiredChallengeBeforeEitherKeySigns() async throws {
        let transportKey = Curve25519.Signing.PrivateKey()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000],
            challengeIssuedAtMillis: 1_000,
            challengeExpiresAtMillis: 2_000
        )
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: IrohRouteFakeAuthorityPublisher(),
            transportKey: transportKey,
            authorityKey: Curve25519.Signing.PrivateKey(),
            nowMillis: { 10_000 }
        )

        do {
            _ = try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identity(for: transportKey)
            )
            XCTFail("An expired server challenge must fail closed")
        } catch {
            XCTAssertEqual(
                error as? IrohControllerRouteRegistrarError,
                .invalidCanonicalPayload
            )
        }
        let signatures = await gateway.recordedSignatures()
        let registerCalls = await gateway.registerCallCount()
        XCTAssertTrue(signatures.isEmpty)
        XCTAssertEqual(registerCalls, 0)
    }

    func testAccountReplacementRejectsInFlightChallengeBeforeSigningOrRegistering() async throws {
        let authenticatedUID = IrohRouteLockedUID("user-1")
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let issueGate = MobileAsyncGate()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000],
            issueGate: issueGate
        )
        let registrar = IrohControllerRouteRegistrar(
            gateway: gateway,
            authorityPublisher: IrohRouteFakeAuthorityPublisher(),
            transportSecretProvider: { transportKey.rawRepresentation },
            authorityIdentityProvider: { .ed25519(authorityKey) },
            authorityPeerNodeIdProvider: { _ in "authority-1" },
            authenticatedUIDProvider: { authenticatedUID.value() },
            nowMillis: { 10_000 }
        )
        let registration = Task {
            try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identity(for: transportKey)
            )
        }
        await gateway.waitForIssueCallCount(1)

        authenticatedUID.set("user-2")
        await issueGate.open()

        do {
            _ = try await registration.value
            XCTFail("Old-account route work must fail after authentication changes")
        } catch {
            XCTAssertEqual(error as? IrohControllerRouteRegistrarError, .routeSuperseded)
        }
        let signatures = await gateway.recordedSignatures()
        let registerCalls = await gateway.registerCallCount()
        XCTAssertTrue(signatures.isEmpty)
        XCTAssertEqual(registerCalls, 0)
    }

    func testSignsExactServerCanonicalBytesWithPersistedTransportIdentity() async throws {
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let events = IrohRouteEventRecorder()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000],
            events: events
        )
        let publisher = IrohRouteFakeAuthorityPublisher(events: events)
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: publisher,
            transportKey: transportKey,
            authorityKey: authorityKey,
            nowMillis: { 10_000 }
        )

        let registration = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity(for: transportKey)
        )

        let issuedCanonicalPayloads = await gateway.issuedCanonicalPayloads()
        let canonicalBytes = try XCTUnwrap(issuedCanonicalPayloads.first)
        let signatures = await gateway.recordedSignatures()
        let signaturePair = try XCTUnwrap(signatures.first)
        let transportSignature = try XCTUnwrap(Data(base64Encoded: signaturePair.transportSignatureBase64))
        let authoritySignatureBase64 = try XCTUnwrap(signaturePair.authoritySignatureBase64)
        let authoritySignature = try XCTUnwrap(Data(base64Encoded: authoritySignatureBase64))
        XCTAssertTrue(transportKey.publicKey.isValidSignature(transportSignature, for: canonicalBytes))
        XCTAssertTrue(authorityKey.publicKey.isValidSignature(authoritySignature, for: canonicalBytes))
        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, ["publish", "issue", "register"])
        XCTAssertEqual(registration.transportNodeId, hex(transportKey.publicKey.rawRepresentation))
        let published = await publisher.publishedValues()
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.peerNodeId, "authority-1")
        XCTAssertEqual(published.first?.publicKeyData, authorityKey.publicKey.rawRepresentation)
        XCTAssertNotEqual(registration.transportNodeId, published.first?.peerNodeId)
    }

    func testRejectsTransportSecretThatDoesNotMatchEndpointBeforePublishing() async throws {
        let persistedTransportKey = Curve25519.Signing.PrivateKey()
        let activeTransportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000]
        )
        let publisher = IrohRouteFakeAuthorityPublisher()
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: publisher,
            transportKey: persistedTransportKey,
            authorityKey: authorityKey,
            nowMillis: { 10_000 }
        )

        do {
            _ = try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identity(for: activeTransportKey)
            )
            XCTFail("Expected mismatched iroh transport identity to fail closed")
        } catch {
            XCTAssertEqual(error as? IrohControllerRouteRegistrarError, .transportIdentityKeyMismatch)
        }
        let issueCalls = await gateway.issueCallCount()
        let publishCalls = await publisher.publishCallCount()
        XCTAssertEqual(issueCalls, 0)
        XCTAssertEqual(publishCalls, 0)
    }

    func testP256AuthorityRenewsAutonomouslyWithTransportProofOnly() async throws {
        let clock = IrohRouteLockedClock(10_000)
        let sleeper = IrohRouteTestSleeper()
        let authenticator = IrohRouteAuthenticationProbe()
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = P256.Signing.PrivateKey()
        let authorityIdentity = PhoneControlAuthoritySigningKey.secureEnclaveP256(authorityKey)
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [11_000, 21_000]
        )
        let registrar = IrohControllerRouteRegistrar(
            gateway: gateway,
            authorityPublisher: IrohRouteFakeAuthorityPublisher(),
            transportSecretProvider: { transportKey.rawRepresentation },
            authorityIdentityProvider: { authorityIdentity },
            authorityBootstrapIdentityProvider: { identity in
                await authenticator.recordAuthentication()
                return identity
            },
            authorityPeerNodeIdProvider: { _ in "authority-p256" },
            authenticatedUIDProvider: { "user-1" },
            nowMillis: { clock.value() },
            sleepMillis: { milliseconds in await sleeper.sleep(milliseconds) },
            renewalLeadMillis: 200
        )

        _ = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity(for: transportKey)
        )

        let bootstrapPayloads = await gateway.issuedCanonicalPayloads()
        let bootstrapBytes = try XCTUnwrap(bootstrapPayloads.first)
        let bootstrapSignatures = await gateway.recordedSignatures()
        let bootstrapPair = try XCTUnwrap(bootstrapSignatures.first)
        let authoritySignatureBase64 = try XCTUnwrap(bootstrapPair.authoritySignatureBase64)
        let authoritySignature = try XCTUnwrap(Data(base64Encoded: authoritySignatureBase64))
        XCTAssertEqual(authoritySignature.count, 64)
        XCTAssertTrue(authorityIdentity.verifyingKey.isValidSignature(authoritySignature, for: bootstrapBytes))

        await sleeper.waitForSleepCount(1)
        let initialDelays = await sleeper.recordedDelays()
        XCTAssertEqual(initialDelays, [800])
        clock.set(10_800)
        await sleeper.resumeNext()
        await gateway.waitForRegisterCallCount(2)

        let payloads = await gateway.issuedCanonicalPayloads()
        let renewalBytes = try XCTUnwrap(payloads.last)
        let signatures = await gateway.recordedSignatures()
        let renewalPair = try XCTUnwrap(signatures.last)
        let renewalTransportSignature = try XCTUnwrap(
            Data(base64Encoded: renewalPair.transportSignatureBase64)
        )
        XCTAssertTrue(transportKey.publicKey.isValidSignature(renewalTransportSignature, for: renewalBytes))
        XCTAssertNil(renewalPair.authoritySignatureBase64)
        let renewedIssueCalls = await gateway.issueCallCount()
        XCTAssertEqual(renewedIssueCalls, 2)
        let authenticationCount = await authenticator.authenticationCount()
        XCTAssertEqual(authenticationCount, 1)
        let renewed = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity(for: transportKey)
        )
        XCTAssertEqual(renewed.generation, 1)
        XCTAssertEqual(renewed.expiresAtMillis, 21_000)

        await registrar.invalidateAll()
        await sleeper.resumeAll()
    }

    func testP256BootstrapAuthenticatesBeforeRegisteringAuthorityProof() async throws {
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityIdentity = PhoneControlAuthoritySigningKey.secureEnclaveP256(
            P256.Signing.PrivateKey()
        )
        let events = IrohRouteEventRecorder()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000],
            events: events
        )
        let registrar = IrohControllerRouteRegistrar(
            gateway: gateway,
            authorityPublisher: IrohRouteFakeAuthorityPublisher(events: events),
            transportSecretProvider: { transportKey.rawRepresentation },
            authorityIdentityProvider: { authorityIdentity },
            authorityBootstrapIdentityProvider: { identity in
                await events.append("authenticate")
                return identity
            },
            authorityPeerNodeIdProvider: { _ in "authority-p256" },
            authenticatedUIDProvider: { "user-1" },
            nowMillis: { 10_000 }
        )

        _ = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity(for: transportKey)
        )

        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, ["publish", "issue", "authenticate", "register"])
        let signatures = await gateway.recordedSignatures()
        XCTAssertNotNil(signatures.first?.authoritySignatureBase64)
        await registrar.invalidateAll()
    }

    func testP256BootstrapAuthenticationCancellationFailsPromptlyWithoutRegistering() async throws {
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityIdentity = PhoneControlAuthoritySigningKey.secureEnclaveP256(
            P256.Signing.PrivateKey()
        )
        let gateway = IrohRouteFakeGateway(registrationExpiries: [20_000])
        let registrar = IrohControllerRouteRegistrar(
            gateway: gateway,
            authorityPublisher: IrohRouteFakeAuthorityPublisher(),
            transportSecretProvider: { transportKey.rawRepresentation },
            authorityIdentityProvider: { authorityIdentity },
            authorityBootstrapIdentityProvider: { _ in
                throw IrohControllerRouteRegistrarError.authorityAuthenticationCancelled
            },
            authorityPeerNodeIdProvider: { _ in "authority-p256" },
            authenticatedUIDProvider: { "user-1" },
            nowMillis: { 10_000 }
        )

        do {
            _ = try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identity(for: transportKey)
            )
            XCTFail("Cancelling bootstrap authentication must fail the connection attempt")
        } catch {
            XCTAssertEqual(
                error as? IrohControllerRouteRegistrarError,
                .authorityAuthenticationCancelled
            )
        }

        let issueCalls = await gateway.issueCallCount()
        let registerCalls = await gateway.registerCallCount()
        let signatures = await gateway.recordedSignatures()
        XCTAssertEqual(issueCalls, 1)
        XCTAssertEqual(registerCalls, 0)
        XCTAssertTrue(signatures.isEmpty)
        await registrar.invalidateAll()
    }

    func testBackgroundP256RenewalFailsClosedWhenServerRequestsBootstrap() async throws {
        let sleeper = IrohRouteTestSleeper()
        let authenticator = IrohRouteAuthenticationProbe()
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityIdentity = PhoneControlAuthoritySigningKey.secureEnclaveP256(
            P256.Signing.PrivateKey()
        )
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000],
            proofKindsByIssue: [.bootstrap, .bootstrap]
        )
        let registrar = IrohControllerRouteRegistrar(
            gateway: gateway,
            authorityPublisher: IrohRouteFakeAuthorityPublisher(),
            transportSecretProvider: { transportKey.rawRepresentation },
            authorityIdentityProvider: { authorityIdentity },
            authorityBootstrapIdentityProvider: { identity in
                await authenticator.recordAuthentication()
                return identity
            },
            authorityPeerNodeIdProvider: { _ in "authority-p256" },
            authenticatedUIDProvider: { "user-1" },
            nowMillis: { 10_000 },
            sleepMillis: { milliseconds in await sleeper.sleep(milliseconds) },
            renewalLeadMillis: 200
        )

        _ = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity(for: transportKey)
        )
        await sleeper.waitForSleepCount(1)
        await sleeper.resumeNext()
        await gateway.waitForIssueCallCount(2)
        await sleeper.waitForSleepCount(2)

        let issueCalls = await gateway.issueCallCount()
        let registerCalls = await gateway.registerCallCount()
        let signatures = await gateway.recordedSignatures()
        XCTAssertEqual(issueCalls, 2)
        XCTAssertEqual(registerCalls, 1)
        XCTAssertEqual(signatures.count, 1)
        XCTAssertNotNil(signatures.first?.authoritySignatureBase64)
        let authenticationCount = await authenticator.authenticationCount()
        XCTAssertEqual(authenticationCount, 1)

        await registrar.invalidateAll()
        await sleeper.resumeAll()
    }

    func testRejectsMismatchedRegistrationResponseAndDoesNotCacheIt() async throws {
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000, 20_000],
            registrationAuthorityPeerNodeIdOverride: "forged-authority"
        )
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: IrohRouteFakeAuthorityPublisher(),
            transportKey: transportKey,
            authorityKey: authorityKey,
            nowMillis: { 10_000 }
        )
        let identity = identity(for: transportKey)

        for _ in 0..<2 {
            do {
                _ = try await registrar.registerIfNeeded(
                    uid: "user-1",
                    connectionId: "connection-1",
                    sourceDeviceId: "device-1",
                    transportIdentity: identity
                )
                XCTFail("A forged registration response must fail closed")
            } catch {
                XCTAssertEqual(error as? IrohControllerRouteRegistrarError, .invalidRegistrationResponse)
            }
        }
        let issueCalls = await gateway.issueCallCount()
        let registerCalls = await gateway.registerCallCount()
        XCTAssertEqual(issueCalls, 2)
        XCTAssertEqual(registerCalls, 2)
    }

    func testConcurrentRegistrationsSingleFlightAndFreshRegistrationIsCached() async throws {
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let gate = MobileAsyncGate()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000],
            issueGate: gate
        )
        let publisher = IrohRouteFakeAuthorityPublisher()
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: publisher,
            transportKey: transportKey,
            authorityKey: authorityKey,
            nowMillis: { 10_000 }
        )
        let identity = identity(for: transportKey)

        async let first = registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )
        async let second = registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )
        await gateway.waitForIssueCallCount(1)
        let inFlightIssueCalls = await gateway.issueCallCount()
        let inFlightPublishCalls = await publisher.publishCallCount()
        XCTAssertEqual(inFlightIssueCalls, 1)
        XCTAssertEqual(inFlightPublishCalls, 1)
        await gate.open()
        let concurrent = try await (first, second)
        XCTAssertEqual(concurrent.0, concurrent.1)

        let cached = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )
        XCTAssertEqual(cached, concurrent.0)
        let cachedIssueCalls = await gateway.issueCallCount()
        let cachedRegisterCalls = await gateway.registerCallCount()
        XCTAssertEqual(cachedIssueCalls, 1)
        XCTAssertEqual(cachedRegisterCalls, 1)
    }

    func testRenewsInsideSafetyWindow() async throws {
        let clock = IrohRouteLockedClock(10_000)
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [11_000, 21_000]
        )
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: IrohRouteFakeAuthorityPublisher(),
            transportKey: transportKey,
            authorityKey: authorityKey,
            nowMillis: { clock.value() },
            renewalLeadMillis: 200
        )
        let identity = identity(for: transportKey)

        _ = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )
        clock.set(10_799)
        _ = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )
        let freshIssueCalls = await gateway.issueCallCount()
        XCTAssertEqual(freshIssueCalls, 1)

        clock.set(10_800)
        let renewed = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )
        let renewedIssueCalls = await gateway.issueCallCount()
        XCTAssertEqual(renewedIssueCalls, 2)
        XCTAssertEqual(renewed.generation, 1)
        XCTAssertEqual(renewed.expiresAtMillis, 21_000)
    }

    func testOwnedLeaseTaskRenewsLongLivedRouteAtSafetyWindow() async throws {
        let clock = IrohRouteLockedClock(10_000)
        let sleeper = IrohRouteTestSleeper()
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [11_000, 21_000]
        )
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: IrohRouteFakeAuthorityPublisher(),
            transportKey: transportKey,
            authorityKey: authorityKey,
            nowMillis: { clock.value() },
            sleepMillis: { milliseconds in await sleeper.sleep(milliseconds) },
            renewalLeadMillis: 200
        )

        _ = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity(for: transportKey)
        )
        await sleeper.waitForSleepCount(1)
        let delays = await sleeper.recordedDelays()
        XCTAssertEqual(delays, [800])

        clock.set(10_800)
        await sleeper.resumeNext()
        await gateway.waitForRegisterCallCount(2)
        let issueCalls = await gateway.issueCallCount()
        XCTAssertEqual(issueCalls, 2)

        await registrar.invalidateAll()
        await sleeper.resumeAll()
    }

    func testFailedRegistrationIsNotCachedAndNextAttemptRetries() async throws {
        let transportKey = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000],
            issueFailures: 1
        )
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: IrohRouteFakeAuthorityPublisher(),
            transportKey: transportKey,
            authorityKey: authorityKey,
            nowMillis: { 10_000 }
        )
        let identity = identity(for: transportKey)

        do {
            _ = try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identity
            )
            XCTFail("Expected injected callable failure")
        } catch {
            XCTAssertEqual(error as? IrohRouteFakeError, .injectedFailure)
        }
        let retried = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )
        XCTAssertEqual(retried.generation, 1)
        let retriedIssueCalls = await gateway.issueCallCount()
        let retriedRegisterCalls = await gateway.registerCallCount()
        XCTAssertEqual(retriedIssueCalls, 2)
        XCTAssertEqual(retriedRegisterCalls, 1)
    }

    func testSupersededInFlightIdentityCannotRestoreCacheOrRenewal() async throws {
        let transportA = Curve25519.Signing.PrivateKey()
        let transportB = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let persistedSecret = IrohRouteLockedSecret(transportA.rawRepresentation)
        let gateA = MobileAsyncGate()
        let sleeper = IrohRouteTestSleeper()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000, 20_000],
            issueGatesByTransportNodeId: [hex(transportA.publicKey.rawRepresentation): gateA]
        )
        let registrar = IrohControllerRouteRegistrar(
            gateway: gateway,
            authorityPublisher: IrohRouteFakeAuthorityPublisher(),
            transportSecretProvider: { persistedSecret.value() },
            authorityIdentityProvider: { .ed25519(authorityKey) },
            authorityPeerNodeIdProvider: { _ in "authority-1" },
            authenticatedUIDProvider: { "user-1" },
            nowMillis: { 10_000 },
            sleepMillis: { milliseconds in await sleeper.sleep(milliseconds) },
            renewalLeadMillis: 200
        )
        let identityA = identity(for: transportA)
        let identityB = identity(for: transportB)
        let superseded = Task {
            try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identityA
            )
        }
        await gateway.waitForIssueCallCount(1)

        // The active endpoint and its persisted seed change before A's
        // callable returns. B must become the sole scope owner.
        persistedSecret.set(transportB.rawRepresentation)
        let activeTask = Task {
            try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identityB
            )
        }
        await waitForActiveTransportNodeId(
            hex(transportB.publicKey.rawRepresentation),
            registrar: registrar
        )
        let serializedIssueCalls = await gateway.issueCallCount()
        XCTAssertEqual(serializedIssueCalls, 1)

        await gateA.open()
        do {
            _ = try await superseded.value
            XCTFail("Superseded endpoint A must not become dialable")
        } catch {
            XCTAssertEqual(error as? IrohControllerRouteRegistrarError, .routeSuperseded)
        }
        let active = try await activeTask.value
        XCTAssertEqual(active.transportNodeId, hex(transportB.publicKey.rawRepresentation))
        await sleeper.waitForSleepCount(1)

        let cachedActive = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identityB
        )
        XCTAssertEqual(cachedActive, active)
        let issueCalls = await gateway.issueCallCount()
        let renewalDelays = await sleeper.recordedDelays()
        XCTAssertEqual(issueCalls, 2)
        XCTAssertEqual(renewalDelays.count, 1)
        await registrar.invalidateAll()
        await sleeper.resumeAll()
    }

    func testHeldStaleServerCommitSerializesSupersedingIdentity() async throws {
        let transportA = Curve25519.Signing.PrivateKey()
        let transportB = Curve25519.Signing.PrivateKey()
        let authorityKey = Curve25519.Signing.PrivateKey()
        let persistedSecret = IrohRouteLockedSecret(transportA.rawRepresentation)
        let staleCommitGate = MobileAsyncGate()
        let gateway = IrohRouteFakeGateway(
            registrationExpiries: [20_000, 20_000],
            registerGatesByTransportNodeId: [hex(transportA.publicKey.rawRepresentation): staleCommitGate]
        )
        let registrar = IrohControllerRouteRegistrar(
            gateway: gateway,
            authorityPublisher: IrohRouteFakeAuthorityPublisher(),
            transportSecretProvider: { persistedSecret.value() },
            authorityIdentityProvider: { .ed25519(authorityKey) },
            authorityPeerNodeIdProvider: { _ in "authority-1" },
            authenticatedUIDProvider: { "user-1" },
            nowMillis: { 10_000 }
        )
        let stale = Task {
            try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identity(for: transportA)
            )
        }
        await gateway.waitForRegisterCallCount(1)

        persistedSecret.set(transportB.rawRepresentation)
        let active = Task {
            try await registrar.registerIfNeeded(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1",
                transportIdentity: identity(for: transportB)
            )
        }
        await waitForActiveTransportNodeId(
            hex(transportB.publicKey.rawRepresentation),
            registrar: registrar
        )
        let heldIssueCalls = await gateway.issueCallCount()
        XCTAssertEqual(heldIssueCalls, 1, "B must wait behind A's server commit")

        await staleCommitGate.open()
        do {
            _ = try await stale.value
            XCTFail("The stale committed route must never become dialable")
        } catch {
            XCTAssertEqual(error as? IrohControllerRouteRegistrarError, .routeSuperseded)
        }
        let activeRegistration = try await active.value
        XCTAssertEqual(activeRegistration.transportNodeId, hex(transportB.publicKey.rawRepresentation))
        let finalIssueCalls = await gateway.issueCallCount()
        let finalRegisterCalls = await gateway.registerCallCount()
        XCTAssertEqual(finalIssueCalls, 2)
        XCTAssertEqual(finalRegisterCalls, 2)
        await registrar.invalidateAll()
    }

    private func waitForActiveTransportNodeId(
        _ expected: String,
        registrar: IrohControllerRouteRegistrar
    ) async {
        for _ in 0..<1_000 {
            if await registrar.activeTransportNodeIdForTesting(
                uid: "user-1",
                connectionId: "connection-1",
                sourceDeviceId: "device-1"
            ) == expected {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for superseding route ownership")
    }

    func testInvalidateAndRevokeClearsLeaseBeforeReuse() async throws {
        let transportKey = Curve25519.Signing.PrivateKey()
        let gateway = IrohRouteFakeGateway(registrationExpiries: [20_000, 20_000])
        let registrar = makeRegistrar(
            gateway: gateway,
            publisher: IrohRouteFakeAuthorityPublisher(),
            transportKey: transportKey,
            authorityKey: Curve25519.Signing.PrivateKey(),
            nowMillis: { 10_000 }
        )
        let identity = identity(for: transportKey)
        _ = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )

        await registrar.invalidateAndRevoke()

        let revocations = await gateway.recordedRevocations()
        XCTAssertEqual(revocations.count, 1)
        XCTAssertEqual(revocations.first?.sourceDeviceId, "device-1")
        XCTAssertEqual(revocations.first?.connectionId, "connection-1")
        _ = try await registrar.registerIfNeeded(
            uid: "user-1",
            connectionId: "connection-1",
            sourceDeviceId: "device-1",
            transportIdentity: identity
        )
        let issueCalls = await gateway.issueCallCount()
        XCTAssertEqual(issueCalls, 2)
        await registrar.invalidateAll()
    }

    private func makeRegistrar(
        gateway: IrohRouteFakeGateway,
        publisher: IrohRouteFakeAuthorityPublisher,
        transportKey: Curve25519.Signing.PrivateKey,
        authorityKey: Curve25519.Signing.PrivateKey,
        nowMillis: @escaping @Sendable () -> Int64,
        sleepMillis: @escaping @Sendable (Int64) async throws -> Void = { _ in
            try await Task.sleep(nanoseconds: UInt64.max)
        },
        renewalLeadMillis: Int64 = 200
    ) -> IrohControllerRouteRegistrar {
        IrohControllerRouteRegistrar(
            gateway: gateway,
            authorityPublisher: publisher,
            transportSecretProvider: { transportKey.rawRepresentation },
            authorityIdentityProvider: { .ed25519(authorityKey) },
            authorityPeerNodeIdProvider: { _ in "authority-1" },
            authenticatedUIDProvider: { "user-1" },
            nowMillis: nowMillis,
            sleepMillis: sleepMillis,
            renewalLeadMillis: renewalLeadMillis
        )
    }

    private func identity(for key: Curve25519.Signing.PrivateKey) -> IrohEndpointIdentity {
        let publicKey = key.publicKey.rawRepresentation
        return IrohEndpointIdentity(nodeId: hex(publicKey), rawPublicKey: publicKey)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private enum IrohRouteFakeError: Error, Equatable {
    case injectedFailure
}

private final class IrohRouteLockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64

    init(_ milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    func value() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return milliseconds
    }

    func set(_ milliseconds: Int64) {
        lock.lock()
        self.milliseconds = milliseconds
        lock.unlock()
    }
}

private final class IrohRouteLockedSecret: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(_ data: Data) {
        self.data = data
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }
}

private final class IrohRouteLockedUID: @unchecked Sendable {
    private let lock = NSLock()
    private var uid: String?

    init(_ uid: String?) {
        self.uid = uid
    }

    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return uid
    }

    func set(_ uid: String?) {
        lock.lock()
        self.uid = uid
        lock.unlock()
    }
}

private actor IrohRouteTestSleeper {
    private var delays: [Int64] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ milliseconds: Int64) async {
        delays.append(milliseconds)
        resumeCountWaiters()
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForSleepCount(_ count: Int) async {
        if delays.count >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func recordedDelays() -> [Int64] {
        delays
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { delays.count >= $0.0 }
        countWaiters.removeAll { delays.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor IrohRouteEventRecorder {
    private var recorded: [String] = []

    func append(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}

private actor IrohRouteAuthenticationProbe {
    private var count = 0

    func recordAuthentication() {
        count += 1
    }

    func authenticationCount() -> Int {
        count
    }
}

private actor IrohRouteFakeAuthorityPublisher: PhoneControlAuthorityPublishing {
    struct Published: Sendable {
        let peerNodeId: String
        let publicKeyData: Data
    }

    private let events: IrohRouteEventRecorder?
    private var values: [Published] = []

    init(events: IrohRouteEventRecorder? = nil) {
        self.events = events
    }

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws {
        values.append(Published(peerNodeId: peerNodeId, publicKeyData: publicKey.rawRepresentation))
        await events?.append("publish")
    }

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKeyRepresentation: Data,
        keyKind: PhoneControlSigningKeyKind
    ) async throws {
        values.append(Published(peerNodeId: peerNodeId, publicKeyData: publicKeyRepresentation))
        await events?.append("publish")
    }

    func publishCallCount() -> Int {
        values.count
    }

    func publishedValues() -> [Published] {
        values
    }
}

private actor IrohRouteFakeGateway: IrohControllerRouteCallableGateway {
    struct RecordedSignatures: Sendable {
        let transportSignatureBase64: String
        let authoritySignatureBase64: String?
    }

    private struct Request: Sendable {
        let sourceDeviceId: String
        let connectionId: String
        let authorityPeerNodeId: String
        let transportNodeId: String
        let generation: Int64
        let proofKind: IrohControllerRouteProofKind
    }

    private let expectedUID: String
    private let canonicalPayloadTransform: @Sendable (Data) -> Data
    private let registrationExpiries: [Int64]
    private let challengeIssuedAtMillis: Int64
    private let challengeExpiresAtMillis: Int64
    private let proofKindsByIssue: [IrohControllerRouteProofKind]?
    private let issueGate: MobileAsyncGate?
    private let issueGatesByTransportNodeId: [String: MobileAsyncGate]
    private let registerGatesByTransportNodeId: [String: MobileAsyncGate]
    private let events: IrohRouteEventRecorder?
    private let registrationAuthorityPeerNodeIdOverride: String?
    private var remainingIssueFailures: Int
    private var issueCalls = 0
    private var registerCalls = 0
    private var requestsByChallengeId: [String: Request] = [:]
    private var registeredRequest: Request?
    private var signatures: [RecordedSignatures] = []
    private var canonicalPayloads: [Data] = []
    private var revocations: [(sourceDeviceId: String, connectionId: String)] = []
    private var issueCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var registerCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        expectedUID: String = "user-1",
        registrationExpiries: [Int64],
        challengeIssuedAtMillis: Int64 = 9_000,
        challengeExpiresAtMillis: Int64 = 19_000,
        proofKindsByIssue: [IrohControllerRouteProofKind]? = nil,
        canonicalPayloadTransform: @escaping @Sendable (Data) -> Data = { $0 },
        issueGate: MobileAsyncGate? = nil,
        issueGatesByTransportNodeId: [String: MobileAsyncGate] = [:],
        registerGatesByTransportNodeId: [String: MobileAsyncGate] = [:],
        events: IrohRouteEventRecorder? = nil,
        issueFailures: Int = 0,
        registrationAuthorityPeerNodeIdOverride: String? = nil
    ) {
        self.expectedUID = expectedUID
        self.canonicalPayloadTransform = canonicalPayloadTransform
        self.registrationExpiries = registrationExpiries
        self.challengeIssuedAtMillis = challengeIssuedAtMillis
        self.challengeExpiresAtMillis = challengeExpiresAtMillis
        self.proofKindsByIssue = proofKindsByIssue
        self.issueGate = issueGate
        self.issueGatesByTransportNodeId = issueGatesByTransportNodeId
        self.registerGatesByTransportNodeId = registerGatesByTransportNodeId
        self.events = events
        self.remainingIssueFailures = issueFailures
        self.registrationAuthorityPeerNodeIdOverride = registrationAuthorityPeerNodeIdOverride
    }

    func issueChallenge(
        expectedUID: String,
        sourceDeviceId: String,
        connectionId: String,
        authorityPeerNodeId: String,
        transportNodeId: String
    ) async throws -> IrohControllerRouteChallenge {
        guard expectedUID == self.expectedUID else { throw IrohRouteFakeError.injectedFailure }
        issueCalls += 1
        let issueNumber = issueCalls
        resumeIssueCallWaiters()
        await events?.append("issue")
        if remainingIssueFailures > 0 {
            remainingIssueFailures -= 1
            throw IrohRouteFakeError.injectedFailure
        }
        if let keyedGate = issueGatesByTransportNodeId[transportNodeId] {
            await keyedGate.wait()
        } else {
            await issueGate?.wait()
        }
        let tupleMatchesRegistered = registeredRequest.map {
            $0.sourceDeviceId == sourceDeviceId
                && $0.connectionId == connectionId
                && $0.authorityPeerNodeId == authorityPeerNodeId
                && $0.transportNodeId == transportNodeId
        } ?? false
        let defaultProofKind: IrohControllerRouteProofKind = tupleMatchesRegistered
            ? .transportRenewal
            : .bootstrap
        let proofKind = proofKindsByIssue.flatMap { proofKinds in
            guard !proofKinds.isEmpty else { return nil }
            return proofKinds[min(issueNumber - 1, proofKinds.count - 1)]
        } ?? defaultProofKind
        let priorGeneration = registeredRequest?.generation ?? 0
        let generation = proofKind == .transportRenewal && tupleMatchesRegistered
            ? priorGeneration
            : priorGeneration + 1
        let challengeId = "challenge-\(issueNumber)"
        let issuedAtMillis = challengeIssuedAtMillis
        let expiresAtMillis = challengeExpiresAtMillis
        requestsByChallengeId[challengeId] = Request(
            sourceDeviceId: sourceDeviceId,
            connectionId: connectionId,
            authorityPeerNodeId: authorityPeerNodeId,
            transportNodeId: transportNodeId,
            generation: generation,
            proofKind: proofKind
        )
        let canonicalPayload = canonicalPayloadTransform(irohRouteProofPayload(
            challengeId: challengeId,
            challengeNonce: "test-nonce-\(issueNumber)",
            proofKind: proofKind,
            uid: expectedUID,
            connectionId: connectionId,
            sourceDeviceId: sourceDeviceId,
            transportNodeId: transportNodeId,
            authorityPeerNodeId: authorityPeerNodeId,
            registrationGeneration: generation,
            issuedAtMillis: issuedAtMillis,
            expiresAtMillis: expiresAtMillis
        ))
        canonicalPayloads.append(canonicalPayload)
        return IrohControllerRouteChallenge(
            challengeId: challengeId,
            canonicalPayloadBase64: canonicalPayload.base64EncodedString(),
            signatureAlgorithm: "ed25519",
            proofKind: proofKind,
            registrationGeneration: generation,
            issuedAtMillis: issuedAtMillis,
            expiresAtMillis: expiresAtMillis
        )
    }

    func register(
        expectedUID: String,
        challengeId: String,
        transportSignatureBase64: String,
        authoritySignatureBase64: String?
    ) async throws -> IrohControllerRouteRegistration {
        guard expectedUID == self.expectedUID else { throw IrohRouteFakeError.injectedFailure }
        registerCalls += 1
        resumeRegisterCallWaiters()
        signatures.append(RecordedSignatures(
            transportSignatureBase64: transportSignatureBase64,
            authoritySignatureBase64: authoritySignatureBase64
        ))
        await events?.append("register")
        guard let request = requestsByChallengeId[challengeId] else {
            throw IrohRouteFakeError.injectedFailure
        }
        switch request.proofKind {
        case .bootstrap:
            guard authoritySignatureBase64 != nil else { throw IrohRouteFakeError.injectedFailure }
        case .transportRenewal:
            guard authoritySignatureBase64 == nil else { throw IrohRouteFakeError.injectedFailure }
        }
        if let gate = registerGatesByTransportNodeId[request.transportNodeId] {
            await gate.wait()
        }
        let expiryIndex = min(max(0, registerCalls - 1), max(0, registrationExpiries.count - 1))
        guard !registrationExpiries.isEmpty else { throw IrohRouteFakeError.injectedFailure }
        registeredRequest = request
        return IrohControllerRouteRegistration(
            connectionId: request.connectionId,
            sourceDeviceId: request.sourceDeviceId,
            transportNodeId: request.transportNodeId,
            authorityPeerNodeId: registrationAuthorityPeerNodeIdOverride ?? request.authorityPeerNodeId,
            generation: request.generation,
            expiresAtMillis: registrationExpiries[expiryIndex]
        )
    }

    func revoke(expectedUID: String, sourceDeviceId: String, connectionId: String) async throws {
        guard expectedUID == self.expectedUID else { throw IrohRouteFakeError.injectedFailure }
        revocations.append((sourceDeviceId, connectionId))
        if registeredRequest?.sourceDeviceId == sourceDeviceId,
           registeredRequest?.connectionId == connectionId {
            registeredRequest = nil
        }
    }

    func issueCallCount() -> Int {
        issueCalls
    }

    func registerCallCount() -> Int {
        registerCalls
    }

    func recordedSignatures() -> [RecordedSignatures] {
        signatures
    }

    func issuedCanonicalPayloads() -> [Data] {
        canonicalPayloads
    }

    func recordedRevocations() -> [(sourceDeviceId: String, connectionId: String)] {
        revocations
    }

    func waitForIssueCallCount(_ expected: Int) async {
        if issueCalls >= expected { return }
        await withCheckedContinuation { continuation in
            issueCallWaiters.append((expected, continuation))
        }
    }

    func waitForRegisterCallCount(_ expected: Int) async {
        if registerCalls >= expected { return }
        await withCheckedContinuation { continuation in
            registerCallWaiters.append((expected, continuation))
        }
    }

    private func resumeIssueCallWaiters() {
        let ready = issueCallWaiters.filter { issueCalls >= $0.0 }
        issueCallWaiters.removeAll { issueCalls >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeRegisterCallWaiters() {
        let ready = registerCallWaiters.filter { registerCalls >= $0.0 }
        registerCallWaiters.removeAll { registerCalls >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private func irohRouteProofPayload(
    challengeId: String,
    challengeNonce: String,
    proofKind: IrohControllerRouteProofKind,
    uid: String,
    connectionId: String,
    sourceDeviceId: String,
    transportNodeId: String,
    authorityPeerNodeId: String,
    registrationGeneration: Int64,
    issuedAtMillis: Int64,
    expiresAtMillis: Int64
) -> Data {
    func framed(_ value: String) -> String {
        "\(value.lengthOfBytes(using: .utf8)):\(value)\n"
    }
    let fields = [
        "version", "2",
        "challengeId", challengeId,
        "challengeNonce", challengeNonce,
        "proofKind", proofKind.rawValue,
        "uid", uid,
        "connectionId", connectionId,
        "sourceDeviceId", sourceDeviceId,
        "transportNodeId", transportNodeId,
        "authorityPeerNodeId", authorityPeerNodeId,
        "registrationGeneration", String(registrationGeneration),
        "issuedAtMillis", String(issuedAtMillis),
        "expiresAtMillis", String(expiresAtMillis)
    ]
    return Data(("OpenBurnBar-IrohControllerRoute-v2\n" + fields.map(framed).joined()).utf8)
}

private enum IrohRouteProofMutation {
    private static let domain = Data("OpenBurnBar-IrohControllerRoute-v2\n".utf8)

    static let malformedFraming: @Sendable (Data) -> Data = { payload in
        var result = payload
        if result.count > IrohRouteProofMutation.domain.count {
            result[IrohRouteProofMutation.domain.count] = 0x38
        }
        return result
    }

    static let invalidUTF8: @Sendable (Data) -> Data = { payload in
        var result = payload
        if let range = result.range(of: Data("test-nonce-1".utf8)) {
            result[range.lowerBound] = 0xff
        }
        return result
    }

    static let extraField: @Sendable (Data) -> Data = { payload in
        payload + Data("5:extra\n1:x\n".utf8)
    }

    static let missingField: @Sendable (Data) -> Data = { payload in
        Data(payload.dropLast(min(8, payload.count)))
    }

    static let wrongUID: @Sendable (Data) -> Data = { payload in
        var result = payload
        if let range = result.range(of: Data("user-1".utf8)) {
            result.replaceSubrange(range, with: Data("user-2".utf8))
        }
        return result
    }

    static let wrongProofKind: @Sendable (Data) -> Data = { payload in
        var result = payload
        if let range = result.range(of: Data("bootstrap".utf8)) {
            result.replaceSubrange(range, with: Data("forgedxxx".utf8))
        }
        return result
    }
}
