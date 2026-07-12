#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class ComputerUseSessionGrantRPCCompositionTests: XCTestCase {
    private func makeCapabilityStateStore(
        at root: URL,
        entitlementIsActive: Bool = true
    ) async throws -> ComputerUseCapabilityStateStore {
        let now = Date()
        let store = ComputerUseCapabilityStateStore(
            fileURL: root.appendingPathComponent("capability-state.json"),
            now: { now }
        )
        let provenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: now,
            updatedAt: now
        )
        _ = try await store.update(ComputerUseCapabilityStateSnapshot(
            publisherInstanceID: "computer-use-session-grant-rpc-composition-tests",
            revision: 1,
            generatedAt: now,
            userID: "linux-test-user",
            entitlement: ComputerUseEntitlementSnapshot(
                isActive: entitlementIsActive,
                productId: ComputerUseEntitlementSnapshot.hostedProductID,
                expireAt: now.addingTimeInterval(3_600),
                allowsBrowser: true,
                allowsSystem: true,
                allowsPhoneControl: true,
                allowsTrustedScopes: true,
                allowsAuditExport: true
            ),
            entitlementProvenance: provenance,
            budgetEnvelope: ComputerUseBudgetEnvelope(
                level: .normal,
                projectedMonthEndUSD: 0,
                monthToDateUSD: 0,
                activeActionsPerRun: 50,
                activeActionsPerDay: 200,
                activeSessionsPerDay: 4,
                perUserDailySpendCeilingUSD: 5,
                updatedAt: now
            ),
            budgetProvenance: provenance,
            quotaUsage: ComputerUseQuotaUsage(
                dayKey: String(ISO8601DateFormatter().string(from: now).prefix(10)),
                updatedAt: now
            ),
            quotaProvenance: provenance,
            concurrentSessionActive: false,
            killSwitch: false,
            isComplete: true
        ))
        return store
    }

    func testReadinessReportsBrokerPairingAndOperationalStates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-readiness-rpc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultServer = makeReadinessServer(root: root.appendingPathComponent("default"))
        let brokerUnavailable = try await readiness(server: defaultServer, id: "broker-unavailable")
        XCTAssertEqual(brokerUnavailable.result?.available, false)
        XCTAssertEqual(brokerUnavailable.result?.reason, .brokerUnavailable)

        let transportUnavailableBroker = ComputerUseSessionGrantBroker(
            publisher: nil,
            prevalidatePinnedPhoneGrant: { _, _, _ in }
        )
        let transportUnavailableServer = makeReadinessServer(
            root: root.appendingPathComponent("transport-unavailable"),
            broker: transportUnavailableBroker
        )
        let transportUnavailable = try await readiness(
            server: transportUnavailableServer,
            id: "transport-unavailable"
        )
        XCTAssertEqual(transportUnavailable.result?.available, false)
        XCTAssertEqual(transportUnavailable.result?.reason, .transportUnavailable)

        let proofUnavailableBroker = ComputerUseSessionGrantBroker(
            publisher: { _, _ in },
            prevalidatePinnedPhoneGrant: nil
        )
        let proofUnavailableServer = makeReadinessServer(
            root: root.appendingPathComponent("proof-unavailable"),
            broker: proofUnavailableBroker
        )
        let proofUnavailable = try await readiness(
            server: proofUnavailableServer,
            id: "proof-unavailable"
        )
        XCTAssertEqual(proofUnavailable.result?.available, false)
        XCTAssertEqual(proofUnavailable.result?.reason, .proofValidatorUnavailable)

        let operationalBroker = ComputerUseSessionGrantBroker(
            publisher: { _, _ in },
            prevalidatePinnedPhoneGrant: { _, _, _ in }
        )
        let unpairedServer = makeReadinessServer(
            root: root.appendingPathComponent("unpaired"),
            broker: operationalBroker
        )
        let pairingUnavailable = try await readiness(server: unpairedServer, id: "pairing-unavailable")
        XCTAssertEqual(pairingUnavailable.result?.available, false)
        XCTAssertEqual(pairingUnavailable.result?.reason, .pairingUnavailable)

        let readyServer = makeReadinessServer(
            root: root.appendingPathComponent("ready"),
            broker: operationalBroker,
            metadataResolver: { _, _ in
                .init(
                    uid: "user-1",
                    connectionID: "connection-1",
                    transportPeerNodeID: "phone-transport-1",
                    authorityPeerNodeID: "phone-authority-1",
                    sourceDeviceID: "phone-device-1",
                    runtimeID: .codex,
                    threadID: "thread-1",
                    preset: .desktop,
                    capabilities: [.desktopBrowser]
                )
            },
            readinessProvider: { true }
        )
        let ready = try await readiness(server: readyServer, id: "ready")
        XCTAssertEqual(ready.result?.available, true)
        XCTAssertEqual(ready.result?.reason, .ready)

        let runtimeNotReadyServer = makeReadinessServer(
            root: root.appendingPathComponent("runtime-not-ready"),
            broker: operationalBroker,
            metadataResolver: { _, _ in throw CompositionTestFailure.invalidPhoneGrant },
            readinessProvider: { false }
        )
        let runtimeNotReady = try await readiness(
            server: runtimeNotReadyServer,
            id: "runtime-not-ready"
        )
        XCTAssertEqual(runtimeNotReady.result?.available, false)
        XCTAssertEqual(runtimeNotReady.result?.reason, .pairingUnavailable)

        let missingStatus: BurnBarRPCResponseEnvelope<ComputerUseSessionGrantStatusResponse> = try await rpc(
            server: defaultServer,
            method: .computerUseSessionGrantStatus,
            id: "missing-status",
            params: ComputerUseSessionGrantStatusRequest(challengeId: "missing")
        )
        XCTAssertEqual(missingStatus.error?.code, BurnBarRPCErrorCode.invalidParams)

        let missingRunStart: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try await rpc(
            server: defaultServer,
            method: .computerUseSessionStart,
            id: "missing-run-start",
            params: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.browser.rawValue,
                trustMode: ComputerUseTrustMode.step.rawValue,
                clientID: BurnBarClientID(rawValue: "missing-run-client")
            )
        )
        XCTAssertEqual(missingRunStart.error?.code, BurnBarRPCErrorCode.invalidParams)

        let inactiveAuditRoot = root.appendingPathComponent("inactive-entitlement", isDirectory: true)
        let inactiveService = ComputerUseService(
            auditBaseDirectory: inactiveAuditRoot,
            capabilityStateStore: try await makeCapabilityStateStore(
                at: inactiveAuditRoot,
                entitlementIsActive: false
            ),
            leafKillSwitch: { false },
            systemInputDispatcher: { _, _ in throw CompositionTestFailure.unexpectedDispatch },
            privilegedInputKillSwitchActivator: { _ in }
        )
        let inactiveServer = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("inactive-entitlement.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-inactive-entitlement-rpc-composition-tests"),
            computerUseService: inactiveService
        )
        do {
            let _: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try await rpc(
                server: inactiveServer,
                method: .computerUseSessionStart,
                id: "unentitled-system-start",
                params: ComputerUseSessionStartRequest(
                    mode: ComputerUseMode.system.rawValue,
                    trustMode: ComputerUseTrustMode.step.rawValue,
                    clientID: BurnBarClientID(rawValue: "unentitled-system-client")
                )
            )
            XCTFail("An unentitled system session must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ComputerUseService.ServiceError,
                .capabilityDenied(ComputerUseDenyReason.entitlement.rawValue)
            )
        }
        let inactiveSessionExists = await inactiveService.hasActiveSession()
        XCTAssertFalse(inactiveSessionExists)

        let barePending = BurnBarRPCRequestEnvelope(
            id: "bare-pending",
            method: .computerUseApprovalPending,
            authToken: "test-token"
        )
        let barePendingData = try await defaultServer.handleComputerUseRPC(
            method: .computerUseApprovalPending,
            decoder: JSONDecoder(),
            requestData: JSONEncoder().encode(barePending)
        )
        let barePendingResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<ComputerUseApprovalPendingResponse>.self,
            from: barePendingData
        )
        XCTAssertEqual(barePendingResponse.result?.requests, [])
        XCTAssertEqual(barePendingResponse.result?.runRequirements, [])
        XCTAssertNil(barePendingResponse.result?.sessionActive)
    }

    func testSignedApprovalRPCRejectsMissingSessionAndMissingPendingRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-approval-rpc-errors-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let verifier = DaemonComputerUseApprovalAuthorityVerifier(
            resolvePinnedKey: { _ in nil },
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(
                fileURL: root.appendingPathComponent("approval-counters.json")
            )
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("daemon.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-approval-rpc-error-tests"),
            localAuthProofVerifier: DaemonLocalAuthProofVerifier(
                resolvePinnedKey: { _ in nil },
                consumeProof: { _, _ in true }
            ),
            computerUseApprovalAuthorityVerifier: verifier
        )
        let response = HermesRealtimeRelayApprovalResponse(
            approvalId: "missing-approval",
            decision: .approve,
            respondedBy: "phone-1",
            respondedAt: Date()
        )

        let missingSession: BurnBarRPCResponseEnvelope<ComputerUseApprovalRespondResponse> = try await rpc(
            server: server,
            method: .computerUseApprovalRespond,
            id: "missing-session",
            params: ComputerUseApprovalRespondRequest(response: response)
        )
        XCTAssertEqual(missingSession.error?.code, BurnBarRPCErrorCode.unauthorized)

        let missingPending: BurnBarRPCResponseEnvelope<ComputerUseApprovalRespondResponse> = try await rpc(
            server: server,
            method: .computerUseApprovalRespond,
            id: "missing-pending",
            params: ComputerUseApprovalRespondRequest(sessionId: "session-1", response: response)
        )
        XCTAssertEqual(missingPending.error?.code, BurnBarRPCErrorCode.unauthorized)
    }

    func testAcquireIngestStatusDenialAndKnownStartFailureRemainRetryableUntilSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-grant-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clientID = BurnBarClientID(rawValue: "linux-shell")
        let sessionID = BurnBarSessionID(rawValue: "linux-shell-session")
        let registry = ComputerUseAuthorizationRegistry(enforcementEnabled: true)
        let sessionStartGate = FailOnceSessionStartGate()
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let capabilityStateStore = try await makeCapabilityStateStore(at: auditRoot)
        let service = ComputerUseService(
            auditBaseDirectory: auditRoot,
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: { _ in
                try sessionStartGate.beforeStart()
                return nil
            },
            privilegedInputKillSwitchActivator: { _ in },
            authorizationRegistry: registry
        )
        let runService = try await makeRunService(
            root: root,
            clientID: clientID,
            sessionID: sessionID,
            registry: registry
        )
        let created = try await runService.createRun(BurnBarRunCreateRequest(
            clientID: clientID,
            sessionID: sessionID,
            prompt: "Extract the current browser page",
            modelID: "glm-5",
            metadata: [
                "toolKind": .string(BurnBarToolKind.browserExtract.rawValue),
                "toolArguments": .object([:])
            ]
        ))
        let pendingRequirement = await runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        let unsignedRequest = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.step.rawValue,
            scopeRuleIds: ["workspace-only"],
            phoneViewerNodeId: "phone-transport-1",
            macHostNodeId: "linux-host-1",
            actionCap: 50,
            sessionTimeoutSeconds: 1_800,
            clientID: clientID,
            runID: requirement.runID,
            runCallID: requirement.invocation.callID,
            runGeneration: requirement.generation,
            desktopOwnerAuthorizationRequest: .init(method: .linuxDesktopOwner)
        )

        let publications = GrantPublicationRecorder()
        let phoneKey = PlatformCrypto.ed25519PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let broker = ComputerUseSessionGrantBroker(
            publisher: { peerNodeID, frame in
                await publications.append(peerNodeID: peerNodeID, frame: frame)
            },
            prevalidatePinnedPhoneGrant: { request, peerNodeID, _ in
                let expectedHash = try signer.canonicalAgentGrantRequestHashHex(request: request)
                guard peerNodeID == "phone-authority-1",
                      request.authority.peerNodeId == peerNodeID,
                      request.authority.intentHashBlake3 == expectedHash,
                      signer.isValidAuthoritySignature(
                        intentHashHex: expectedHash,
                        counter: request.authority.counter,
                        timestamp: request.authority.timestamp,
                        signatureBase64: request.authority.signatureEd25519,
                        key: .ed25519(phoneKey.publicKey)
                      ) else {
                    throw CompositionTestFailure.invalidPhoneGrant
                }
            },
            randomBytes: { count in Data((0..<count).map { UInt8($0) }) },
            challengeIDGenerator: { "challenge-rpc-composition" }
        )
        let proofLedger = LocalAuthProofConsumptionRecorder()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { candidate in
                candidate == "phone-device-1" ? .ed25519(phoneKey.publicKey) : nil
            },
            consumeProof: { proofID, expiresAt in
                proofLedger.consume(proofID: proofID, expiresAt: expiresAt)
            }
        )
        let ownerAuthorization = DenyOnceOwnerAuthorizer()
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("daemon.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-grant-rpc-composition-tests"),
            runService: runService,
            computerUseService: service,
            computerUseAuthorizationRegistry: registry,
            localAuthProofVerifier: verifier,
            computerUseSessionGrantBroker: broker,
            computerUseSessionGrantMetadataResolver: { _, _ in
                .init(
                    uid: "user-1",
                    connectionID: "connection-1",
                    transportPeerNodeID: "phone-transport-1",
                    authorityPeerNodeID: "phone-authority-1",
                    sourceDeviceID: "phone-device-1",
                    runtimeID: .codex,
                    threadID: "thread-1",
                    preset: .desktop,
                    capabilities: [.desktopBrowser, .desktopScreenshot]
                )
            },
            linuxComputerUseOwnerAuthorizer: { peerPID, operationID, reason in
                try ownerAuthorization.authorize(
                    peerPID: peerPID,
                    operationID: operationID,
                    reason: reason
                )
            }
        )

        let invalidAcquire: BurnBarRPCResponseEnvelope<ComputerUseSessionGrantStatusResponse> = try await rpc(
            server: server,
            method: .computerUseSessionGrantAcquire,
            id: "invalid-acquire",
            params: ComputerUseSessionGrantAcquireRequest(
                sessionRequest: ComputerUseSessionStartRequest(
                    mode: ComputerUseMode.system.rawValue,
                    trustMode: ComputerUseTrustMode.step.rawValue,
                    clientID: clientID
                )
            )
        )
        XCTAssertEqual(invalidAcquire.error?.code, BurnBarRPCErrorCode.invalidParams)

        let brokerUnavailableServer = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("broker-unavailable.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-grant-rpc-broker-unavailable-tests"),
            runService: runService,
            computerUseService: service,
            computerUseAuthorizationRegistry: registry
        )
        let brokerUnavailable: BurnBarRPCResponseEnvelope<ComputerUseSessionGrantStatusResponse> = try await rpc(
            server: brokerUnavailableServer,
            method: .computerUseSessionGrantAcquire,
            id: "broker-unavailable",
            params: ComputerUseSessionGrantAcquireRequest(sessionRequest: unsignedRequest)
        )
        XCTAssertEqual(brokerUnavailable.error?.code, BurnBarRPCErrorCode.internalError)

        let resolverFailureServer = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("resolver-failure.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-grant-rpc-resolver-failure-tests"),
            runService: runService,
            computerUseService: service,
            computerUseAuthorizationRegistry: registry,
            computerUseSessionGrantBroker: broker,
            computerUseSessionGrantMetadataResolver: { _, _ in
                throw CompositionTestFailure.invalidPhoneGrant
            }
        )
        let resolverFailure: BurnBarRPCResponseEnvelope<ComputerUseSessionGrantStatusResponse> = try await rpc(
            server: resolverFailureServer,
            method: .computerUseSessionGrantAcquire,
            id: "resolver-failure",
            params: ComputerUseSessionGrantAcquireRequest(sessionRequest: unsignedRequest)
        )
        XCTAssertEqual(resolverFailure.error?.code, BurnBarRPCErrorCode.unauthorized)

        let localAuthOnlyServer = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("local-auth-only.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-grant-rpc-local-auth-only-tests"),
            runService: runService,
            computerUseService: service,
            computerUseAuthorizationRegistry: registry,
            localAuthProofVerifier: verifier
        )
        let missingPairedAuthority: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try await rpc(
            server: localAuthOnlyServer,
            method: .computerUseSessionStart,
            id: "missing-paired-authority",
            params: unsignedRequest,
            peerPID: 42
        )
        XCTAssertEqual(missingPairedAuthority.error?.code, BurnBarRPCErrorCode.unauthorized)

        let prepareFailureServer = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("prepare-failure.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-grant-rpc-prepare-failure-tests"),
            runService: runService,
            computerUseService: service,
            computerUseAuthorizationRegistry: registry,
            localAuthProofVerifier: verifier,
            computerUseSessionGrantBroker: broker
        )
        let missingChallengeRequest = ComputerUseSessionStartRequest(
            mode: unsignedRequest.mode,
            trustMode: unsignedRequest.trustMode,
            scopeRuleIds: unsignedRequest.scopeRuleIds,
            phoneViewerNodeId: unsignedRequest.phoneViewerNodeId,
            macHostNodeId: unsignedRequest.macHostNodeId,
            actionCap: unsignedRequest.actionCap,
            sessionTimeoutSeconds: unsignedRequest.sessionTimeoutSeconds,
            clientID: unsignedRequest.clientID,
            runID: unsignedRequest.runID,
            runCallID: unsignedRequest.runCallID,
            runGeneration: unsignedRequest.runGeneration,
            grantChallengeId: "missing-challenge",
            desktopOwnerAuthorizationRequest: unsignedRequest.desktopOwnerAuthorizationRequest
        )
        let missingChallenge: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try await rpc(
            server: prepareFailureServer,
            method: .computerUseSessionStart,
            id: "missing-challenge",
            params: missingChallengeRequest,
            peerPID: 42
        )
        XCTAssertEqual(missingChallenge.error?.code, BurnBarRPCErrorCode.unauthorized)

        let acquired: BurnBarRPCResponseEnvelope<ComputerUseSessionGrantStatusResponse> = try await rpc(
            server: server,
            method: .computerUseSessionGrantAcquire,
            id: "acquire",
            params: ComputerUseSessionGrantAcquireRequest(sessionRequest: unsignedRequest)
        )
        XCTAssertNil(acquired.error)
        XCTAssertEqual(acquired.result?.state, .awaitingPhone)
        let challengeID = try XCTUnwrap(acquired.result?.challengeId)
        let pendingPublication = await publications.first()
        let publication = try XCTUnwrap(pendingPublication)
        XCTAssertEqual(publication.peerNodeID, "phone-transport-1")
        let challenge = try XCTUnwrap(publication.frame.control?.sessionGrantChallenge)

        let now = Date()
        var phoneGrant = try AgentCapabilityGrantRequest(
            validatedSessionChallenge: challenge,
            sourceDeviceID: "phone-device-1",
            localAuthenticationSatisfied: true,
            now: now
        )
        let intentHash = try signer.canonicalAgentGrantRequestHashHex(binding: phoneGrant.localAuthGrantBinding)
        phoneGrant.localAuthProof = try signer.signLocalAuthProof(
            proofId: "proof-rpc-composition",
            deviceId: "phone-device-1",
            signedIntentHash: intentHash,
            authenticatedAt: now,
            expiresAt: challenge.expiresAt,
            privateKey: phoneKey
        )
        let unsignedWireGrant = phoneGrant.wire(authority: HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: now,
            intentHashBlake3: "",
            signatureEd25519: ""
        ))
        let signedAuthority = try signer.sign(
            request: unsignedWireGrant,
            peerNodeId: "phone-authority-1",
            counter: 1,
            timestamp: now,
            privateKey: phoneKey
        )
        let wireGrant = phoneGrant.wire(authority: HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signedAuthority.peerNodeId,
            counter: signedAuthority.counter,
            timestamp: signedAuthority.timestamp,
            intentHashBlake3: signedAuthority.intentHashHex,
            signatureEd25519: signedAuthority.signatureBase64
        ))
        try await server.ingestComputerUseSessionGrant(
            wireGrant,
            authenticatedTransportPeerNodeID: "phone-transport-1",
            now: now
        )

        let ready: BurnBarRPCResponseEnvelope<ComputerUseSessionGrantStatusResponse> = try await rpc(
            server: server,
            method: .computerUseSessionGrantStatus,
            id: "ready-status",
            params: ComputerUseSessionGrantStatusRequest(challengeId: challengeID)
        )
        XCTAssertEqual(ready.result?.state, .ready)

        let startRequest = ComputerUseSessionStartRequest(
            mode: unsignedRequest.mode,
            trustMode: unsignedRequest.trustMode,
            scopeRuleIds: unsignedRequest.scopeRuleIds,
            phoneViewerNodeId: unsignedRequest.phoneViewerNodeId,
            macHostNodeId: unsignedRequest.macHostNodeId,
            actionCap: unsignedRequest.actionCap,
            sessionTimeoutSeconds: unsignedRequest.sessionTimeoutSeconds,
            clientID: unsignedRequest.clientID,
            runID: unsignedRequest.runID,
            runCallID: unsignedRequest.runCallID,
            runGeneration: unsignedRequest.runGeneration,
            grantChallengeId: challengeID,
            desktopOwnerAuthorizationRequest: unsignedRequest.desktopOwnerAuthorizationRequest
        )
        let denied: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try await rpc(
            server: server,
            method: .computerUseSessionStart,
            id: "denied-start",
            params: startRequest,
            peerPID: 4242
        )
        XCTAssertNil(denied.result)
        XCTAssertNotNil(denied.error)
        XCTAssertEqual(ownerAuthorization.attemptCount, 1)
        XCTAssertEqual(proofLedger.consumedCount, 0)
        let statusAfterDenial = await broker.status(challengeID: challengeID)
        XCTAssertEqual(statusAfterDenial?.state, .ready)

        do {
            let _: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try await rpc(
                server: server,
                method: .computerUseSessionStart,
                id: "known-failed-start",
                params: startRequest,
                peerPID: 4242
            )
            XCTFail("Expected the injected definite start failure")
        } catch {
            XCTAssertEqual(error as? CompositionTestFailure, .knownStartFailure)
        }
        XCTAssertEqual(ownerAuthorization.attemptCount, 2)
        XCTAssertEqual(sessionStartGate.attemptCount, 1)
        XCTAssertEqual(proofLedger.consumedCount, 0)
        let statusAfterKnownFailure = await broker.status(challengeID: challengeID)
        XCTAssertEqual(statusAfterKnownFailure?.state, .ready)

        let started: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try await rpc(
            server: server,
            method: .computerUseSessionStart,
            id: "successful-start",
            params: startRequest,
            peerPID: 4242
        )
        let startedSessionID = try XCTUnwrap(started.result?.sessionId)
        XCTAssertNil(started.error)
        XCTAssertEqual(ownerAuthorization.attemptCount, 3)
        XCTAssertEqual(sessionStartGate.attemptCount, 2)
        XCTAssertEqual(proofLedger.consumedCount, 1)
        let statusAfterStart = await broker.status(challengeID: challengeID)
        XCTAssertEqual(statusAfterStart?.state, .consumed)

        _ = try await service.panicHalt(ComputerUsePanicHaltRequest(
            sessionId: startedSessionID,
            source: ComputerUsePanicSource.revoked.rawValue
        ))
    }

    private func makeRunService(
        root: URL,
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        registry: ComputerUseAuthorizationRegistry
    ) async throws -> BurnBarRunService {
        let configStore = BurnBarConfigStore(
            fileURL: root.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "cu-grant-rpc-composition-tests")
        )
        try await configStore.setSecret("zai-secret", for: "zai")
        _ = try await configStore.upsertProvider(BurnBarProviderSettings(
            providerID: "zai",
            isEnabled: true,
            baseURL: "https://api.z.ai/api/coding/paas/v4",
            preferredModelIDs: ["glm-5"]
        ))
        let clientRegistry = BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "cu-grant-rpc-composition-tests")
        )
        _ = await clientRegistry.attach(BurnBarClientAttachRequest(
            clientID: clientID,
            sessionID: sessionID,
            clientName: "Linux grant RPC composition tests",
            supportedProtocolVersions: BurnBarProtocolVersion.supported
        ))
        return BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "cu-grant-rpc-composition-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: root.appendingPathComponent("usage.jsonl"),
                logger: BurnBarDaemonLogger(category: "cu-grant-rpc-composition-tests")
            ),
            clientRegistry: clientRegistry,
            runJournal: BurnBarRunJournal(
                fileURL: root.appendingPathComponent("run-journal.jsonl"),
                checkpointsDirectoryURL: root.appendingPathComponent("run-checkpoints", isDirectory: true),
                logger: BurnBarDaemonLogger(category: "cu-grant-rpc-composition-tests")
            ),
            computerUseBrowserDispatcher: { _ in throw CompositionTestFailure.unexpectedDispatch },
            computerUseRunBindingChecker: { runID, generation in
                await registry.hasActiveBinding(runID: runID, generation: generation)
            },
            logger: BurnBarDaemonLogger(category: "cu-grant-rpc-composition-tests")
        )
    }

    private func makeReadinessServer(
        root: URL,
        broker: ComputerUseSessionGrantBroker? = nil,
        metadataResolver: ComputerUseSessionGrantMetadataResolver? = nil,
        readinessProvider: ComputerUseSessionGrantReadinessProvider? = nil
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("daemon.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-readiness-rpc-composition-tests"),
            computerUseSessionGrantBroker: broker,
            computerUseSessionGrantMetadataResolver: metadataResolver,
            computerUseSessionGrantReadinessProvider: readinessProvider
        )
    }

    private func readiness(
        server: BurnBarDaemonServer,
        id: String
    ) async throws -> BurnBarRPCResponseEnvelope<ComputerUseSessionGrantReadinessResponse> {
        let envelope = BurnBarRPCRequestEnvelope(
            id: id,
            method: .computerUseSessionGrantReadiness,
            authToken: "test-token"
        )
        let response = try await server.handleComputerUseRPC(
            method: .computerUseSessionGrantReadiness,
            decoder: JSONDecoder(),
            requestData: JSONEncoder().encode(envelope)
        )
        return try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<ComputerUseSessionGrantReadinessResponse>.self,
            from: response
        )
    }

    private func rpc<Params: Codable & Sendable, Result: Codable & Sendable>(
        server: BurnBarDaemonServer,
        method: BurnBarRPCMethod,
        id: String,
        params: Params,
        peerPID: Int32? = nil
    ) async throws -> BurnBarRPCResponseEnvelope<Result> {
        let envelope = BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: method,
            authToken: "test-token",
            params: params
        )
        let response = try await server.handleComputerUseRPC(
            method: method,
            decoder: JSONDecoder(),
            requestData: JSONEncoder().encode(envelope),
            peerPID: peerPID
        )
        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Result>.self, from: response)
    }
}

private enum CompositionTestFailure: Error, Equatable {
    case invalidPhoneGrant
    case knownStartFailure
    case ownerAuthorizationDenied
    case unexpectedDispatch
}

private actor GrantPublicationRecorder {
    struct Publication: Sendable {
        let peerNodeID: String
        let frame: HermesRealtimeRelayFrame
    }

    private var publications: [Publication] = []

    func append(peerNodeID: String, frame: HermesRealtimeRelayFrame) {
        publications.append(Publication(peerNodeID: peerNodeID, frame: frame))
    }

    func first() -> Publication? {
        publications.first
    }
}

private final class DenyOnceOwnerAuthorizer: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func authorize(peerPID: Int32, operationID: String, reason: String) throws {
        XCTAssertEqual(peerPID, 4242)
        XCTAssertFalse(operationID.isEmpty)
        XCTAssertTrue(reason.contains("Authorize Browser Computer Use"))
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            throw CompositionTestFailure.ownerAuthorizationDenied
        }
    }
}

private final class FailOnceSessionStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func beforeStart() throws {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            throw CompositionTestFailure.knownStartFailure
        }
    }
}

private final class LocalAuthProofConsumptionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var consumedProofIDs: Set<String> = []

    var consumedCount: Int {
        lock.withLock { consumedProofIDs.count }
    }

    func consume(proofID: String, expiresAt: Date) -> Bool {
        lock.withLock {
            guard expiresAt > Date(), consumedProofIDs.contains(proofID) == false else { return false }
            consumedProofIDs.insert(proofID)
            return true
        }
    }
}
#endif
