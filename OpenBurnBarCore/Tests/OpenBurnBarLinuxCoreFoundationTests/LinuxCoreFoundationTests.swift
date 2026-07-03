import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
#if os(Linux)
import OpenBurnBarSignalCore
import OpenBurnBarSignalSessionTransport
#endif

final class LinuxCoreFoundationTests: XCTestCase {
    func testProviderModelFixtureChecksumAndContracts() throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "linux-provider-model-parity-fixture",
            withExtension: "json"
        ))
        let checksumURL = try XCTUnwrap(Bundle.module.url(
            forResource: "linux-provider-model-parity-fixture",
            withExtension: "sha256"
        ))
        let data = try Data(contentsOf: fixtureURL)
        let expectedChecksum = try String(contentsOf: checksumURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedData = try Self.makeProviderModelParityFixtureData()
        try Self.writeIfRequested(
            data: generatedData,
            environmentKey: "OPENBURNBAR_MODEL_PARITY_OUTPUT"
        )
        try Self.writeIfRequested(
            data: Data(Self.sha256Hex(generatedData).utf8),
            environmentKey: "OPENBURNBAR_MODEL_PARITY_CHECKSUM_OUTPUT"
        )

        XCTAssertEqual(data, generatedData)
        XCTAssertEqual(Self.sha256Hex(data), expectedChecksum)

        let fixture = try Self.fixtureDecoder().decode(LinuxProviderModelFixture.self, from: data)
        XCTAssertEqual(fixture.schema, "openburnbar-core-model-parity-v2")
        XCTAssertEqual(fixture.generatedBy, Self.modelParityGeneratorPath)

        for provider in fixture.providers {
            let agentProvider = try XCTUnwrap(AgentProvider(rawValue: provider.displayName))
            XCTAssertEqual(agentProvider.persistedToken, provider.persistedToken)
            XCTAssertEqual(agentProvider.providerID.rawValue, provider.providerID)
            XCTAssertEqual(agentProvider.isQuotaSignalProvider, provider.quotaSignal)
        }

        let codexBucket = try XCTUnwrap(fixture.quotaBuckets.first { $0.name == "codex-primary" })
        XCTAssertEqual(codexBucket.key, "codex-primary::rollinghours")
        XCTAssertEqual(codexBucket.label, "Codex primary")
        XCTAssertEqual(codexBucket.resetsAt, ISO8601DateFormatter().date(from: "2026-07-03T02:00:00Z"))

        XCTAssertEqual(ComputerUseMode(rawValue: fixture.computerUse.mode), .browser)
        XCTAssertEqual(ComputerUseTrustMode(rawValue: fixture.computerUse.trustMode), .manual)
        XCTAssertEqual(fixture.computerUse.actionCap, 50)
        XCTAssertEqual(fixture.computerUse.sessionTimeoutSeconds, 1_800)

        let modes = Dictionary(uniqueKeysWithValues: fixture.themeModes.map { ($0.rawValue, $0) })
        XCTAssertEqual(modes["standard"]?.displayName, UIMode.standard.displayName)
        XCTAssertEqual(modes["standard"]?.description, UIMode.standard.description)
        XCTAssertEqual(modes["standard"]?.iconName, UIMode.standard.iconName)
        XCTAssertEqual(modes["cooking"]?.displayName, UIMode.cooking.displayName)
        XCTAssertEqual(Set(fixture.skins.map(\.rawValue)), Set(AppSkin.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(fixture.dashboardLayouts.map(\.rawValue)), Set(DashboardLayout.allCases.map(\.rawValue)))
        XCTAssertEqual(fixture.dashboardLayouts.first { $0.rawValue == DashboardLayout.atelier.rawValue }?.isKernelForward, true)

        print("MODEL_FIXTURE_SHA256 \(expectedChecksum)")
        print("MODEL_PARITY_GENERATOR_PATH \(Self.modelParityGeneratorPath)")
    }

    func testPlatformCryptoKATsFromCommittedFixture() throws {
        let computed = try Self.makePlatformCryptoKATFixture()
        let computedData = try PlatformCrypto.canonicalJSONData(computed)
        try Self.writeIfRequested(
            data: computedData,
            environmentKey: "OPENBURNBAR_PLATFORM_CRYPTO_KAT_OUTPUT"
        )

        guard let fixtureURL = Bundle.module.url(
            forResource: "platform-crypto-kats",
            withExtension: "json"
        ) else {
            if ProcessInfo.processInfo.environment["OPENBURNBAR_PLATFORM_CRYPTO_KAT_OUTPUT"] != nil {
                return
            }
            XCTFail("Missing committed platform-crypto-kats.json fixture.")
            return
        }

        let fixtureData = try Data(contentsOf: fixtureURL)
        XCTAssertEqual(fixtureData, computedData)
        let fixture = try Self.fixtureDecoder().decode(PlatformCryptoKATFixture.self, from: fixtureData)

        let hashMessage = try Self.data(base64: fixture.hash.messageBase64)
        XCTAssertEqual(PlatformCrypto.sha256Hex(hashMessage), fixture.hash.sha256Hex)

        let hmacKey = try Self.data(hex: fixture.hmac.keyHex)
        let hmacMessage = try Self.data(base64: fixture.hmac.messageBase64)
        XCTAssertEqual(try PlatformCrypto.hmacSHA256Hex(hmacMessage, keyData: hmacKey), fixture.hmac.hmacSHA256Hex)

        let aesKey = try Self.data(hex: fixture.aesGCM.keyHex)
        let nonce = try Self.data(hex: fixture.aesGCM.nonceHex)
        let aad = Data(fixture.aesGCM.aad.utf8)
        let plaintext = try Self.data(base64: fixture.aesGCM.plaintextBase64)
        let sealed = try PlatformCrypto.sealAESGCM(
            plaintext: plaintext,
            keyData: aesKey,
            nonce: nonce,
            authenticating: aad
        )
        XCTAssertEqual(Self.hexString(sealed), fixture.aesGCM.combinedHex)
        XCTAssertEqual(try PlatformCrypto.openAESGCM(combined: sealed, keyData: aesKey, authenticating: aad), plaintext)

        let privateKey = try Self.data(hex: fixture.ed25519.privateKeyHex)
        let publicKey = try Self.data(hex: fixture.ed25519.publicKeyHex)
        let signingMessage = try Self.data(base64: fixture.ed25519.messageBase64)
        let signature = try PlatformCrypto.ed25519Signature(message: signingMessage, privateKeyRaw: privateKey)
        let fixtureSignature = try Self.data(hex: fixture.ed25519.signatureHex)
        XCTAssertEqual(Self.hexString(try PlatformCrypto.ed25519PublicKeyRaw(privateKeyRaw: privateKey)), fixture.ed25519.publicKeyHex)
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(try PlatformCrypto.verifyEd25519Signature(signature, message: signingMessage, publicKeyRaw: publicKey))
        XCTAssertTrue(try PlatformCrypto.verifyEd25519Signature(fixtureSignature, message: signingMessage, publicKeyRaw: publicKey))

        let canonicalData = try PlatformCrypto.canonicalJSONData(Self.canonicalProbe())
        XCTAssertEqual(String(data: canonicalData, encoding: .utf8), fixture.canonicalJSON.encodedString)
        XCTAssertEqual(PlatformCrypto.sha256Hex(canonicalData), fixture.canonicalJSON.sha256Hex)

        var tamperedCiphertext = sealed
        tamperedCiphertext[tamperedCiphertext.index(before: tamperedCiphertext.endIndex)] ^= 0x01
        XCTAssertThrowsError(try PlatformCrypto.openAESGCM(
            combined: tamperedCiphertext,
            keyData: aesKey,
            authenticating: aad
        )) { error in
            XCTAssertEqual(error as? PlatformCryptoError, .invalidCiphertext)
        }
        XCTAssertThrowsError(try PlatformCrypto.openAESGCM(
            combined: sealed,
            keyData: aesKey,
            authenticating: Data("wrong-aad".utf8)
        )) { error in
            XCTAssertEqual(error as? PlatformCryptoError, .invalidCiphertext)
        }
        XCTAssertThrowsError(try PlatformCrypto.sealAESGCM(
            plaintext: plaintext,
            keyData: Data(repeating: 1, count: 31),
            nonce: nonce,
            authenticating: aad
        )) { error in
            XCTAssertEqual(error as? PlatformCryptoError, .invalidSymmetricKey)
        }
        XCTAssertThrowsError(try PlatformCrypto.sealAESGCM(
            plaintext: plaintext,
            keyData: aesKey,
            nonce: Data(repeating: 1, count: 11),
            authenticating: aad
        )) { error in
            XCTAssertEqual(error as? PlatformCryptoError, .invalidNonce)
        }
        XCTAssertThrowsError(try PlatformCrypto.hmacSHA256(Data(), keyData: Data())) { error in
            XCTAssertEqual(error as? PlatformCryptoError, .invalidSymmetricKey)
        }
        XCTAssertThrowsError(try PlatformCrypto.ed25519Signature(
            message: signingMessage,
            privateKeyRaw: Data(repeating: 1, count: 31)
        )) { error in
            XCTAssertEqual(error as? PlatformCryptoError, .invalidSigningKey)
        }
        XCTAssertThrowsError(try PlatformCrypto.verifyEd25519Signature(
            signature,
            message: signingMessage,
            publicKeyRaw: Data(repeating: 1, count: 31)
        )) { error in
            XCTAssertEqual(error as? PlatformCryptoError, .invalidVerifyingKey)
        }
        var tamperedSignature = signature
        tamperedSignature[0] ^= 0x01
        XCTAssertFalse(try PlatformCrypto.verifyEd25519Signature(
            tamperedSignature,
            message: signingMessage,
            publicKeyRaw: publicKey
        ))
        XCTAssertThrowsError(try PlatformCrypto.canonicalJSONData(ThrowingEncodable())) { error in
            if case .canonicalEncodingFailed = error as? PlatformCryptoError {
                return
            }
            XCTFail("Expected canonicalEncodingFailed, got \(error)")
        }

        let receiver = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        let hpkeAAD = HermesRelayCrypto.controlSealKeyAAD(
            uid: "user-123",
            connectionID: "conn-abc",
            peerNodeId: "mac-peer",
            senderDeviceID: "phone",
            senderKeyID: "key-1",
            senderCounter: 9
        )
        let hpkeWrap = try HermesRelayCrypto.sealKeyV3(
            aesKey,
            recipientPublicKeyBase64: receiver.publicKeyBase64,
            senderPrivateKey: sender,
            aad: hpkeAAD
        )
        XCTAssertEqual(try HermesRelayCrypto.openKeyV3(
            enc: hpkeWrap.enc,
            wrappedKey: hpkeWrap.wrappedKey,
            privateKey: receiver,
            pinnedSenderPublicKeyBase64: sender.publicKeyBase64,
            aad: hpkeAAD
        ), aesKey)
        XCTAssertThrowsError(try HermesRelayCrypto.openKeyV3(
            enc: hpkeWrap.enc,
            wrappedKey: hpkeWrap.wrappedKey,
            privateKey: receiver,
            pinnedSenderPublicKeyBase64: sender.publicKeyBase64,
            aad: Data("wrong-hpke-aad".utf8)
        ))

        let cloudContext = try CloudVaultAADContext(
            uid: "user-123",
            collection: "vaults",
            docID: "doc-1",
            field: "payload"
        )
        let vaultKey = aesKey
        let sealedPayload = try CloudVaultCrypto.sealPayload(
            plaintext,
            keyData: vaultKey,
            vaultKeyID: try CloudVaultCrypto.vaultKeyID(for: vaultKey),
            aadContext: cloudContext
        )
        XCTAssertEqual(try CloudVaultCrypto.openPayload(
            sealedPayload,
            keyData: vaultKey,
            aadContext: cloudContext
        ), plaintext)
        let wrongCloudContext = try CloudVaultAADContext(
            uid: "user-123",
            collection: "vaults",
            docID: "doc-2",
            field: "payload"
        )
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(
            sealedPayload,
            keyData: vaultKey,
            aadContext: wrongCloudContext
        ))

        print("KAT_PLATFORM_CRYPTO_SHA256 \(Self.sha256Hex(fixtureData))")
        print("KAT_HASH_SHA256 \(fixture.hash.sha256Hex)")
        print("KAT_HMAC_SHA256 \(fixture.hmac.hmacSHA256Hex)")
        print("KAT_AES_GCM_COMBINED_SHA256 \(Self.sha256Hex(sealed))")
        print("KAT_ED25519_SIGNATURE_SHA256 \(Self.sha256Hex(fixtureSignature))")
        print("KAT_CANONICAL_JSON_SHA256 \(fixture.canonicalJSON.sha256Hex)")
        print("KAT_HPKE_V3_OPENED_SHA256 \(Self.sha256Hex(aesKey))")
        print("KAT_CLOUDVAULT_PAYLOAD_SHA256 \(Self.sha256Hex(plaintext))")
    }

    func testPlatformCryptoAndLoggerSeams() throws {
        let randomBytes = try PlatformCrypto.secureRandomBytes(count: 32)
        XCTAssertEqual(randomBytes.count, 32)
        XCTAssertNotEqual(randomBytes, Data(repeating: 0, count: 32))

        XCTAssertThrowsError(try PlatformCrypto.secureRandomBytes(count: 0)) { error in
            XCTAssertEqual(error as? PlatformCryptoError, .invalidByteCount)
        }

        let originalSink = PlatformLogger.sink
        let capture = LogCapture()
        PlatformLogger.sink = { level, subsystem, category, message in
            capture.append(level: level, subsystem: subsystem, category: category, message: message)
        }
        defer { PlatformLogger.sink = originalSink }

        PlatformLogger(subsystem: "dev.openburnbar.tests", category: "linux").info("core logger seam")
        XCTAssertEqual(capture.records(), [
            LogRecord(
                level: .info,
                subsystem: "dev.openburnbar.tests",
                category: "linux",
                message: "core logger seam"
            )
        ])
    }

    func testHermesAndMediaKATsFromFixture() throws {
        let fixture = try Self.loadFixture()
        let aad = fixture.aadVectors
        XCTAssertEqual(
            Self.sha256Hex(HermesRelayCrypto.requestAAD(
                uid: aad.uid,
                connectionID: aad.connectionID,
                requestID: aad.requestID
            )),
            aad.hermesRequestSHA256Hex
        )
        XCTAssertEqual(
            Self.sha256Hex(HermesRelayCrypto.keyAAD(
                uid: aad.uid,
                connectionID: aad.connectionID,
                requestID: aad.requestID
            )),
            aad.hermesKeySHA256Hex
        )
        XCTAssertEqual(
            Self.sha256Hex(HermesRelayCrypto.chunkAAD(
                uid: aad.uid,
                connectionID: aad.connectionID,
                requestID: aad.requestID,
                sequence: aad.hermesChunkSequence,
                kind: aad.hermesChunkKind
            )),
            aad.hermesChunkSHA256Hex
        )
        XCTAssertEqual(
            Self.sha256Hex(PiAgentRelayCrypto.requestAAD(
                uid: aad.uid,
                connectionID: aad.connectionID,
                requestID: aad.requestID
            )),
            aad.piAgentRequestSHA256Hex
        )

        let media = fixture.media
        let payload = try XCTUnwrap(Data(base64Encoded: media.payloadBase64))
        let frame = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe, .hasCursorMetadata],
            gopID: media.gopID,
            frameIndex: media.frameIndex,
            presentationTimestampMillis: media.presentationTimestampMillis,
            cursor: .init(x: media.cursor.x, y: media.cursor.y),
            payload: payload
        )
        let envelope = try MediaPacketCodec().encode(frame)
        XCTAssertEqual(Self.hexString(envelope), media.wireHex)
        XCTAssertEqual(Self.sha256Hex(envelope), media.wireSHA256Hex)
        let decoded = try MediaPacketCodec().decode(envelope)
        XCTAssertEqual(decoded.frame, frame)
        XCTAssertEqual(decoded.consumed, envelope.count)

        print("KAT_HERMES_REQUEST_AAD_SHA256 \(aad.hermesRequestSHA256Hex)")
        print("KAT_MEDIA_WIRE_SHA256 \(media.wireSHA256Hex)")
    }

    func testHermesHTTPTransportUsesOfflineFoundationNetworkingStub() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineURLProtocol.self]
        let session = URLSession(configuration: config)
        let requestCapture = RequestCapture()
        OfflineURLProtocol.handler = { request in
            requestCapture.append(request)
            let body = """
            data: {"choices":[{"delta":{"content":"hel"}}]}

            data: {"choices":[{"delta":{"content":"lo"}}],"usage":{"prompt_tokens":5,"completion_tokens":7,"cache_read_input_tokens":2,"estimated_cost_usd":0.001}}

            data: [DONE]

            """
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!,
                Data(body.utf8)
            )
        }
        defer { OfflineURLProtocol.handler = nil }

        let transport = HermesInsightHTTPTransport(
            baseURL: URL(string: "https://offline.openburnbar.invalid")!,
            authorizationHeader: "Bearer test-token",
            urlSession: session
        )
        let request = HermesInsightChatRequest(
            modelID: "hermes-linux-kat",
            systemPrompt: "Return compact JSON.",
            userPayload: Data(#"{"question":"ping"}"#.utf8),
            capabilityTier: .jsonObject,
            prefersAnswerLatency: true,
            maxOutputTokens: 64
        )

        var chunks: [HermesInsightChunk] = []
        for try await chunk in transport.streamAnalysisCompletion(request: request) {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, [
            .delta("hel"),
            .delta("lo"),
            .usage(HermesInsightTokenUsage(
                inputTokens: 5,
                outputTokens: 7,
                cacheReadTokens: 2,
                estimatedCostUSD: 0.001
            )),
            .completed(fullAnswer: "hello")
        ])
        let captured = try XCTUnwrap(requestCapture.requests().first)
        XCTAssertEqual(captured.url?.path, "/v1/chat/completions")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try XCTUnwrap(captured.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["model"] as? String, "hermes-linux-kat")
    }

    #if os(Linux)
    func testNativeSignalAtRestContractsUseLibSignal() throws {
        let wrapA = CloudVaultSignalAtRestWrap(
            recipientKind: "device",
            recipientIdentityKeyId: "b",
            recipientIdentityKeyB64: "public-b",
            sealedContentKeyB64: "sealed-b"
        )
        let wrapB = CloudVaultSignalAtRestWrap(
            recipientKind: "device",
            recipientIdentityKeyId: "a",
            recipientIdentityKeyB64: "public-a",
            sealedContentKeyB64: "sealed-a"
        )
        let authMessage = OpenBurnBarSignalAtRest.senderAuthSignedMessage(
            info: "info",
            payloadCiphertextB64: "payload",
            wraps: [wrapA, wrapB]
        )
        XCTAssertEqual(
            Self.sha256Hex(authMessage),
            "a4bc91528d241f0af0933b125eba960f00df36192aaa64ea7e84248c90fa4bfa"
        )

        let identity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "linux-device")
        let binding = SignalEnvelopeAAD.Binding(
            uid: "user-123",
            scope: .cloudvault,
            collection: "vaults",
            docId: "doc-1",
            field: "payload",
            mode: .atRest,
            formatVersion: 1
        )
        let plaintext = Data("native linux signal payload".utf8)
        let ciphertext = try OpenBurnBarSignalAtRest.atRestSeal(
            plaintext,
            recipientIdentityPublicKey: identity.publicKeyData,
            binding: binding
        )
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertEqual(
            try OpenBurnBarSignalAtRest.atRestOpen(
                ciphertext,
                recipientIdentityPrivateKey: identity.privateKeyData,
                binding: binding
            ),
            plaintext
        )

        let relocated = SignalEnvelopeAAD.Binding(
            uid: "user-123",
            scope: .cloudvault,
            collection: "vaults",
            docId: "doc-relocated",
            field: "payload",
            mode: .atRest,
            formatVersion: 1
        )
        XCTAssertThrowsError(try OpenBurnBarSignalAtRest.atRestOpen(
            ciphertext,
            recipientIdentityPrivateKey: identity.privateKeyData,
            binding: relocated
        ))

        print("NATIVE_SIGNAL_STATUS libsignal=available publicKeyBytes=\(identity.publicKeyData.count) ciphertextBytes=\(ciphertext.count)")
    }

    func testNativeFFIAvailabilityEvidenceIsExplicit() throws {
        XCTAssertNotNil(OpenBurnBarIrohFFIBackendFactory.make())
        XCTAssertNotNil(OpenBurnBarIrohBlobFFIBackendFactory.make())

        let signalIdentity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "native-ffi-status")
        XCTAssertEqual(signalIdentity.keyVersion, 1)
        XCTAssertFalse(signalIdentity.publicKeyData.isEmpty)
        XCTAssertFalse(signalIdentity.privateKeyData.isEmpty)
        XCTAssertEqual(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports: true, remoteSupports: true), true)
        XCTAssertEqual(ComputerUseMode.browser.rawValue, "browser")

        print("NATIVE_FFI_STATUS signal=native-libsignal iroh=native-openburnbar-iroh media=pure-swift-contract cu=pure-swift-contract")
    }
    #endif

    func testIrohLoopbackRoundTripsRelayFrame() async throws {
        let rendezvous = LoopbackIrohRelayRendezvous()
        let host = LoopbackIrohRelayTransport(nodeId: "host-node", rendezvous: rendezvous)
        let client = LoopbackIrohRelayTransport(nodeId: "client-node", rendezvous: rendezvous)
        let hostIdentity = try await host.start()
        _ = try await client.start()

        async let accepted = host.accept(timeout: 1)
        let outgoing = try await client.connect(to: IrohDialTarget(identity: hostIdentity), timeout: 1)
        let incoming = try await accepted
        let frame = HermesRealtimeRelayFrame(
            type: .ping,
            uid: "user-123",
            connectionId: "conn-abc",
            requestId: "req-001",
            runtime: "linux-core-test"
        )

        try await outgoing.send(frame)
        let received = try await incoming.receive()
        XCTAssertEqual(received, frame)
        await outgoing.close()
        await incoming.close()
    }

    func testZComputerUseAuditExportRoundTripsThroughZlib() throws {
        let base = try Self.makeTempDir(prefix: "linux-cu-export")
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionID = ComputerUseSessionID("linux-zlib-session")
        let logger = try ComputerUseAuditLogger(
            sessionId: sessionID,
            baseDirectory: base,
            macAppVersion: "linux-core-test"
        )
        try logger.beginSession(manifest: ComputerUseSessionManifest(
            sessionId: sessionID,
            mode: .browser,
            trustMode: .manual,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            userId: "user-123",
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: 50,
            sessionTimeoutSeconds: 1_800
        ))
        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "#approve")),
            approvedBy: .mac
        ))

        let archive = base.appendingPathComponent("linux-zlib-session.tar.gz")
        let writer = ComputerUseAuditExportWriter()
        let result = try writer.export(
            sessionDirectory: base.appendingPathComponent(sessionID.rawValue),
            destinationURL: archive,
            includeScreenshots: false
        )
        let archiveData = try Data(contentsOf: archive)
        XCTAssertEqual(Array(archiveData.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(result.entryCount, 3)
        XCTAssertGreaterThan(result.archiveSizeBytes, 0)

        let entries = try writer.verify(archive: archive)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.contains { $0.path == "manifest.json" })
        XCTAssertTrue(entries.contains { $0.path == "chain.jsonl" })
        XCTAssertTrue(entries.contains { $0.path == "head.json" })
        print("KAT_CU_GZIP_SHA256 \(Self.sha256Hex(archiveData))")
    }

    private static func loadFixture() throws -> LinuxProviderModelFixture {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "linux-provider-model-parity-fixture",
            withExtension: "json"
        ))
        return try fixtureDecoder().decode(
            LinuxProviderModelFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
    }

    private static let modelParityGeneratorPath =
        "OpenBurnBarCore/Tests/OpenBurnBarLinuxCoreFoundationTests/LinuxCoreFoundationTests.swift"

    private static func makeProviderModelParityFixtureData() throws -> Data {
        try PlatformCrypto.canonicalJSONData(makeProviderModelParityFixture())
    }

    private static func makeProviderModelParityFixture() throws -> LinuxProviderModelFixture {
        let payload = Data("media".utf8)
        let frame = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe, .hasCursorMetadata],
            gopID: 7,
            frameIndex: 2,
            presentationTimestampMillis: 123_456_789,
            cursor: .init(x: 12, y: -34),
            payload: payload
        )
        let envelope = try MediaPacketCodec().encode(frame)
        let aad = AADVectors(
            uid: "user-123",
            connectionID: "conn-abc",
            requestID: "req-001",
            hermesRequestSHA256Hex: PlatformCrypto.sha256Hex(HermesRelayCrypto.requestAAD(
                uid: "user-123",
                connectionID: "conn-abc",
                requestID: "req-001"
            )),
            hermesKeySHA256Hex: PlatformCrypto.sha256Hex(HermesRelayCrypto.keyAAD(
                uid: "user-123",
                connectionID: "conn-abc",
                requestID: "req-001"
            )),
            hermesChunkSequence: 3,
            hermesChunkKind: "delta",
            hermesChunkSHA256Hex: PlatformCrypto.sha256Hex(HermesRelayCrypto.chunkAAD(
                uid: "user-123",
                connectionID: "conn-abc",
                requestID: "req-001",
                sequence: 3,
                kind: "delta"
            )),
            piAgentRequestSHA256Hex: PlatformCrypto.sha256Hex(PiAgentRelayCrypto.requestAAD(
                uid: "user-123",
                connectionID: "conn-abc",
                requestID: "req-001"
            ))
        )
        return LinuxProviderModelFixture(
            schema: "openburnbar-core-model-parity-v2",
            generatedBy: modelParityGeneratorPath,
            providers: [.codex, .claudeCode, .openBurnBar].map(ProviderFixture.init(provider:)),
            quotaBuckets: [
                ProviderQuotaBucket(
                    name: "codex-primary",
                    used: 12,
                    limit: 100,
                    remaining: 88,
                    window: ProviderQuotaWindowKind.rollingHours.rawValue,
                    meta: ["label": "Codex primary", "resetsAt": "2026-07-03T02:00:00Z"],
                    resetsAt: try date("2026-07-03T02:00:00Z")
                ),
                ProviderQuotaBucket(
                    name: "openburnbar-hosted",
                    used: 3,
                    limit: 10,
                    remaining: 7,
                    window: ProviderQuotaWindowKind.daily.rawValue,
                    meta: ["label": "Hosted agent"],
                    resetsAt: try date("2026-07-04T00:00:00Z")
                )
            ],
            themeModes: UIMode.allCases.map(ThemeModeFixture.init(mode:)),
            skins: AppSkin.allCases.map(SkinFixture.init(skin:)),
            dashboardLayouts: DashboardLayout.allCases.map(DashboardLayoutFixture.init(layout:)),
            computerUse: ComputerUseFixture(
                sessionId: "linux-core-session",
                mode: ComputerUseMode.browser.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                actionCap: 50,
                sessionTimeoutSeconds: 1_800
            ),
            media: MediaFixture(
                kind: "videoNAL",
                flags: ["keyframe", "hasCursorMetadata"],
                gopID: frame.gopID,
                frameIndex: frame.frameIndex,
                presentationTimestampMillis: frame.presentationTimestampMillis,
                cursor: .init(x: 12, y: -34),
                payloadBase64: payload.base64EncodedString(),
                wireHex: hexString(envelope),
                wireSHA256Hex: sha256Hex(envelope)
            ),
            aadVectors: aad
        )
    }

    private static func makePlatformCryptoKATFixture() throws -> PlatformCryptoKATFixture {
        let hashMessage = Data("OpenBurnBar hash KAT".utf8)
        let hmacKey = try data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let hmacMessage = Data("OpenBurnBar HMAC KAT".utf8)
        let aesKey = try data(hex: "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
        let nonce = try data(hex: "101112131415161718191a1b")
        let aad = "OpenBurnBar-KAT-AAD-v1"
        let plaintext = Data("OpenBurnBar platform crypto KAT".utf8)
        let privateKey = try data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let signingMessage = Data("OpenBurnBar Ed25519 KAT".utf8)
        let canonicalData = try PlatformCrypto.canonicalJSONData(canonicalProbe())

        return PlatformCryptoKATFixture(
            schema: "openburnbar-platform-crypto-kat-v1",
            generatedBy: modelParityGeneratorPath,
            hash: .init(
                messageBase64: hashMessage.base64EncodedString(),
                sha256Hex: PlatformCrypto.sha256Hex(hashMessage)
            ),
            hmac: .init(
                keyHex: hexString(hmacKey),
                messageBase64: hmacMessage.base64EncodedString(),
                hmacSHA256Hex: try PlatformCrypto.hmacSHA256Hex(hmacMessage, keyData: hmacKey)
            ),
            aesGCM: .init(
                keyHex: hexString(aesKey),
                nonceHex: hexString(nonce),
                aad: aad,
                plaintextBase64: plaintext.base64EncodedString(),
                combinedHex: hexString(try PlatformCrypto.sealAESGCM(
                    plaintext: plaintext,
                    keyData: aesKey,
                    nonce: nonce,
                    authenticating: Data(aad.utf8)
                ))
            ),
            ed25519: .init(
                privateKeyHex: hexString(privateKey),
                publicKeyHex: hexString(try PlatformCrypto.ed25519PublicKeyRaw(privateKeyRaw: privateKey)),
                messageBase64: signingMessage.base64EncodedString(),
                signatureHex: "e6f03ecb85d6e73f4f19f8a76353e0e977bc81d3fe3f4994148778bfa30c1a6701cf2791bdb04f7ff7de0ea2bbb6922e42eba38325123a4993202dfd11975204"
            ),
            canonicalJSON: .init(
                encodedString: String(data: canonicalData, encoding: .utf8) ?? "",
                sha256Hex: PlatformCrypto.sha256Hex(canonicalData)
            )
        )
    }

    private static func canonicalProbe() -> CanonicalProbe {
        CanonicalProbe(
            enabled: true,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            labels: ["linux", "macos", "swiftpm"],
            metadata: [
                "alpha": "one",
                "omega": "last"
            ],
            name: "openburnbar",
            version: 2
        )
    }

    private static func date(_ isoString: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: isoString) else {
            throw FixtureGenerationError.invalidDate(isoString)
        }
        return date
    }

    private static func fixtureDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func data(base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw FixtureGenerationError.invalidBase64(base64)
        }
        return data
    }

    private static func data(hex: String) throws -> Data {
        let characters = Array(hex)
        guard characters.count.isMultiple(of: 2) else {
            throw FixtureGenerationError.invalidHex(hex)
        }
        var output = Data()
        output.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            let pair = String(characters[index..<(index + 2)])
            guard let byte = UInt8(pair, radix: 16) else {
                throw FixtureGenerationError.invalidHex(hex)
            }
            output.append(byte)
            index += 2
        }
        return output
    }

    private static func writeIfRequested(data: Data, environmentKey: String) throws {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], path.isEmpty == false else {
            return
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    private static func makeTempDir(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sha256Hex(_ data: Data) -> String {
        PlatformCrypto.sha256Hex(data)
    }

    private static func hexString(_ data: Data) -> String {
        PlatformCrypto.hexString(data)
    }
}

private enum FixtureGenerationError: Error {
    case invalidBase64(String)
    case invalidDate(String)
    case invalidHex(String)
}

private struct LinuxProviderModelFixture: Codable {
    var schema: String
    var generatedBy: String
    var providers: [ProviderFixture]
    var quotaBuckets: [ProviderQuotaBucket]
    var themeModes: [ThemeModeFixture]
    var skins: [SkinFixture]
    var dashboardLayouts: [DashboardLayoutFixture]
    var computerUse: ComputerUseFixture
    var media: MediaFixture
    var aadVectors: AADVectors
}

private struct ProviderFixture: Codable {
    var displayName: String
    var persistedToken: String
    var providerID: String
    var quotaSignal: Bool

    init(displayName: String, persistedToken: String, providerID: String, quotaSignal: Bool) {
        self.displayName = displayName
        self.persistedToken = persistedToken
        self.providerID = providerID
        self.quotaSignal = quotaSignal
    }

    init(provider: AgentProvider) {
        self.displayName = provider.rawValue
        self.persistedToken = provider.persistedToken
        self.providerID = provider.providerID.rawValue
        self.quotaSignal = provider.isQuotaSignalProvider
    }
}

private struct ThemeModeFixture: Codable {
    var rawValue: String
    var displayName: String
    var description: String
    var iconName: String

    init(rawValue: String, displayName: String, description: String, iconName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        self.iconName = iconName
    }

    init(mode: UIMode) {
        self.rawValue = mode.rawValue
        self.displayName = mode.displayName
        self.description = mode.description
        self.iconName = mode.iconName
    }
}

private struct SkinFixture: Codable {
    var rawValue: String
    var displayName: String
    var storageKey: String

    init(rawValue: String, displayName: String, storageKey: String) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.storageKey = storageKey
    }

    init(skin: AppSkin) {
        self.rawValue = skin.rawValue
        self.displayName = skin.displayName
        self.storageKey = AppSkin.storageKey
    }
}

private struct DashboardLayoutFixture: Codable {
    var rawValue: String
    var displayName: String
    var symbolName: String
    var isKernelForward: Bool
    var storageKey: String

    init(
        rawValue: String,
        displayName: String,
        symbolName: String,
        isKernelForward: Bool,
        storageKey: String
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.symbolName = symbolName
        self.isKernelForward = isKernelForward
        self.storageKey = storageKey
    }

    init(layout: DashboardLayout) {
        self.rawValue = layout.rawValue
        self.displayName = layout.displayName
        self.symbolName = layout.symbolName
        self.isKernelForward = layout.isKernelForward
        self.storageKey = DashboardLayout.storageKey
    }
}

private struct ComputerUseFixture: Codable {
    var sessionId: String
    var mode: String
    var trustMode: String
    var actionCap: Int
    var sessionTimeoutSeconds: Int
}

private struct MediaFixture: Codable {
    struct Cursor: Codable {
        var x: Int16
        var y: Int16
    }

    var kind: String
    var flags: [String]
    var gopID: UInt32
    var frameIndex: UInt32
    var presentationTimestampMillis: UInt64
    var cursor: Cursor
    var payloadBase64: String
    var wireHex: String
    var wireSHA256Hex: String
}

private struct AADVectors: Codable {
    var uid: String
    var connectionID: String
    var requestID: String
    var hermesRequestSHA256Hex: String
    var hermesKeySHA256Hex: String
    var hermesChunkSequence: Int
    var hermesChunkKind: String
    var hermesChunkSHA256Hex: String
    var piAgentRequestSHA256Hex: String
}

private struct PlatformCryptoKATFixture: Codable {
    var schema: String
    var generatedBy: String
    var hash: HashKAT
    var hmac: HMACKAT
    var aesGCM: AESGCMKAT
    var ed25519: Ed25519KAT
    var canonicalJSON: CanonicalJSONKAT

    struct HashKAT: Codable {
        var messageBase64: String
        var sha256Hex: String
    }

    struct HMACKAT: Codable {
        var keyHex: String
        var messageBase64: String
        var hmacSHA256Hex: String
    }

    struct AESGCMKAT: Codable {
        var keyHex: String
        var nonceHex: String
        var aad: String
        var plaintextBase64: String
        var combinedHex: String
    }

    struct Ed25519KAT: Codable {
        var privateKeyHex: String
        var publicKeyHex: String
        var messageBase64: String
        var signatureHex: String
    }

    struct CanonicalJSONKAT: Codable {
        var encodedString: String
        var sha256Hex: String
    }
}

private struct CanonicalProbe: Codable {
    var enabled: Bool
    var generatedAt: Date
    var labels: [String]
    var metadata: [String: String]
    var name: String
    var version: Int
}

private struct ThrowingEncodable: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ThrowingString())
    }
}

private struct ThrowingString: Encodable {
    func encode(to encoder: Encoder) throws {
        throw FixtureGenerationError.invalidHex("throwing-encodable")
    }
}

private struct LogRecord: Equatable {
    var level: PlatformLogLevel
    var subsystem: String
    var category: String
    var message: String
}

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [LogRecord] = []

    func append(level: PlatformLogLevel, subsystem: String, category: String, message: String) {
        lock.lock()
        captured.append(LogRecord(level: level, subsystem: subsystem, category: category, message: message))
        lock.unlock()
    }

    func records() -> [LogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        captured.append(request)
        lock.unlock()
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private final class OfflineURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
