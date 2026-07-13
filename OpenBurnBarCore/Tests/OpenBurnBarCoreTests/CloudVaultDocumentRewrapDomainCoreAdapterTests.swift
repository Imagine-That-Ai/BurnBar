import Foundation
import XCTest
@testable import OpenBurnBarCore

final class CloudVaultDocumentRewrapDomainCoreAdapterTests: XCTestCase {
    private let oldKey = Data(repeating: 0x71, count: 32)
    private let newKey = Data(repeating: 0x72, count: 32)

    func testMigrationModeDefaultsUnknownValuesToLegacy() {
        let key = CloudVaultDocumentRewrapMigrationMode.environmentKey
        XCTAssertEqual(CloudVaultDocumentRewrapMigrationMode.resolve(environment: [:]), .legacy)
        XCTAssertEqual(CloudVaultDocumentRewrapMigrationMode.resolve(environment: [key: "SHADOW"]), .shadow)
        XCTAssertEqual(CloudVaultDocumentRewrapMigrationMode.resolve(environment: [key: "rust"]), .rust)
        XCTAssertEqual(CloudVaultDocumentRewrapMigrationMode.resolve(environment: [key: "future"]), .legacy)
    }

    func testLegacyModeUsesNamedNoncePlanWithoutLoadingNative() throws {
        let recorder = RewrapRecorder()
        let source = try mixedSource()
        let expected = CloudVaultDocumentRewrapResult(data: ["legacy": true], changedFields: ["legacy"])
        var nonceByte: UInt8 = 0x20

        let result = try invoke(
            source,
            mode: .legacy,
            recorder: recorder,
            backend: recorder.backend(result: .empty),
            nonceGenerator: {
                nonceByte += 1
                return Data(repeating: nonceByte, count: 12)
            }
        ) { plan in
            recorder.legacyCalls += 1
            XCTAssertEqual(plan.map(\.fieldName), ["sealedBlobA", "sealedPayload", "sealedTextZ"])
            XCTAssertEqual(plan.map { $0.bytes.first }, [0x21, 0x22, 0x23])
            return expected
        }

        XCTAssertEqual(result.changedFields, expected.changedFields)
        XCTAssertEqual(result.data["legacy"] as? Bool, true)
        XCTAssertEqual(recorder.nativeCalls, 0)
        XCTAssertEqual(recorder.legacyCalls, 1)
        XCTAssertTrue(recorder.diagnostics.isEmpty)
    }

    func testUnknownEnvironmentModePreservesPermissiveLegacyPath() throws {
        let recorder = RewrapRecorder()
        let malformedForStrictLowering: [String: Any] = ["field": ["nonce": "AA=="]]
        let expected = CloudVaultDocumentRewrapResult(data: malformedForStrictLowering, changedFields: [])
        let result = try CloudVaultDocumentRewrapDomainCoreAdapter.rewrap(
            data: malformedForStrictLowering,
            uid: "userA",
            collection: "collectionA",
            docID: "docA",
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: try CloudVaultCrypto.vaultKeyID(for: newKey),
            vaultGeneration: nil,
            rotationJobID: nil,
            environment: [CloudVaultDocumentRewrapMigrationMode.environmentKey: "future"],
            logger: recorder,
            backend: recorder.backend(result: .empty),
            nonceGenerator: { XCTFail("Malformed legacy field requested a nonce"); return Data() },
            legacy: { plan in
                recorder.legacyCalls += 1
                XCTAssertTrue(plan.isEmpty)
                return expected
            }
        )

        XCTAssertEqual(result.changedFields, expected.changedFields)
        XCTAssertEqual(recorder.legacyCalls, 1)
        XCTAssertEqual(recorder.nativeCalls, 0)
    }

    func testRustModeLowersOneLexicographicDocumentCallAndAppliesEveryIntent() throws {
        let recorder = RewrapRecorder()
        let createdAt = TimestampSentinel()
        let source = try mixedSource(createdAt: createdAt)
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        var nonceByte: UInt8 = 0x30
        let backend = recorder.backend { request, receivedOldKey, receivedNewKey, receivedKeyID in
            XCTAssertEqual(receivedOldKey, self.oldKey)
            XCTAssertEqual(receivedNewKey, self.newKey)
            XCTAssertEqual(receivedKeyID, newVaultKeyID)
            XCTAssertEqual(request.documentFieldNames, request.documentFieldNames.sorted())
            XCTAssertEqual(request.envelopes.map(\.fieldName), ["sealedBlobA", "sealedPayload", "sealedTextZ"])
            XCTAssertEqual(request.noncePlan.map(\.fieldName), ["sealedBlobA", "sealedPayload", "sealedTextZ"])
            XCTAssertEqual(request.noncePlan.map { $0.bytes.first }, [0x31, 0x32, 0x33])
            return self.successResult(request: request, newVaultKeyID: newVaultKeyID)
        }

        let result = try invoke(
            source,
            mode: .rust,
            recorder: recorder,
            backend: backend,
            vaultGeneration: 9,
            rotationJobID: "job-9",
            nonceGenerator: {
                nonceByte += 1
                return Data(repeating: nonceByte, count: 12)
            }
        ) { _ in
            recorder.legacyCalls += 1
            throw TestError.legacy
        }

        XCTAssertEqual(recorder.nativeCalls, 1)
        XCTAssertEqual(recorder.legacyCalls, 0)
        XCTAssertEqual(result.changedFields, ["sealedBlobA", "sealedPayload", "sealedTextZ"])
        XCTAssertEqual(result.data["plainStatus"] as? String, "queued")
        XCTAssertEqual(result.data["vaultKeyID"] as? String, newVaultKeyID)
        XCTAssertEqual(result.data["vaultGeneration"] as? Int, 9)
        XCTAssertEqual(result.data["rewrapJobId"] as? String, "job-9")
        let blob = try XCTUnwrap(result.data["sealedBlobA"] as? [String: Any])
        XCTAssertTrue(blob["createdAt"] as AnyObject === createdAt)
    }

    func testDocumentPermutationKeepsEnvelopeAndNamedNonceOrderingStable() throws {
        let source = try mixedSource()
        let permutations: [[String]] = [
            Array(source.keys),
            Array(source.keys.reversed()),
            source.keys.sorted()
        ]
        for order in permutations {
            let recorder = RewrapRecorder()
            let permuted = Dictionary(uniqueKeysWithValues: order.compactMap { key in
                source[key].map { (key, $0) }
            })
            var nonceByte: UInt8 = 0x40
            _ = try invoke(
                permuted,
                mode: .rust,
                recorder: recorder,
                backend: recorder.backend { request, _, _, keyID in
                    XCTAssertEqual(request.envelopes.map(\.fieldName), ["sealedBlobA", "sealedPayload", "sealedTextZ"])
                    XCTAssertEqual(request.noncePlan.map(\.fieldName), ["sealedBlobA", "sealedPayload", "sealedTextZ"])
                    return self.successResult(request: request, newVaultKeyID: keyID)
                },
                nonceGenerator: {
                    nonceByte += 1
                    return Data(repeating: nonceByte, count: 12)
                },
                legacy: { _ in throw TestError.legacy }
            )
            XCTAssertEqual(recorder.nativeCalls, 1)
        }
    }

    func testAlreadyNewPayloadIsAuthenticatedSkipWithNoNonce() throws {
        let recorder = RewrapRecorder()
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        let envelope = try CloudVaultCrypto.sealPayload(
            Data("already new".utf8),
            keyData: newKey,
            vaultKeyID: newVaultKeyID,
            aadContext: CloudVaultAADContext(
                uid: "userA",
                collection: "collectionA",
                docID: "docA",
                field: "sealedPayload"
            )
        )
        let source: [String: Any] = [
            "vaultKeyID": newVaultKeyID,
            "sealedPayload": try CloudVaultCrypto.firestoreDictionary(envelope)
        ]
        var nonceCalls = 0

        let result = try invoke(
            source,
            mode: .rust,
            recorder: recorder,
            backend: recorder.backend { request, _, _, _ in
                XCTAssertTrue(request.noncePlan.isEmpty)
                return .init(
                    changedFields: [],
                    skippedFields: ["sealedPayload"],
                    rewrappedEnvelopes: [],
                    companionIntents: [],
                    preservedMemberIntents: [],
                    vaultGenerationUpdate: nil,
                    rotationJobIDUpdate: nil
                )
            },
            nonceGenerator: {
                nonceCalls += 1
                return Data(repeating: 1, count: 12)
            },
            legacy: { _ in throw TestError.legacy }
        )

        XCTAssertFalse(result.changed)
        XCTAssertEqual(nonceCalls, 0)
        XCTAssertEqual(recorder.nativeCalls, 1)
    }

    func testAmbiguousPartialUnknownAndReservedEnvelopeMapsRejectBeforeExecution() throws {
        let validPayload = try payloadMap(key: oldKey)
        let reservedFields = [
            "vaultKeyID", "sealedStateVaultKeyID", "vaultGeneration",
            "rewrapJobId", "rewrapJobID", "rotationJobId", "rotationJobID"
        ]
        let invalidMaps: [[String: Any]] = [
            [
                "field": validPayload.merging([
                    "nonce": "AA==", "ciphertext": "AA==", "tag": "AA=="
                ]) { left, _ in left }
            ],
            ["field": ["nonce": "AA=="]],
            ["field": validPayload.merging(["futureMember": 1]) { left, _ in left }],
            ["field": validPayload.merging(["schemaVersion": true]) { _, right in right }]
        ] + reservedFields.map { [$0: validPayload] }
        for source in invalidMaps {
            let recorder = RewrapRecorder()
            XCTAssertThrowsError(
                try invoke(
                    source,
                    mode: .rust,
                    recorder: recorder,
                    backend: recorder.backend(result: .empty),
                    nonceGenerator: { Data(repeating: 1, count: 12) },
                    legacy: { _ in recorder.legacyCalls += 1; return .init(data: source, changedFields: []) }
                )
            )
            XCTAssertEqual(recorder.nativeCalls, 0)
            XCTAssertEqual(recorder.legacyCalls, 0)
        }
    }

    func testShadowLegacyThrowNeverTouchesNative() throws {
        let recorder = RewrapRecorder()
        XCTAssertThrowsError(
            try invoke(
                try mixedSource(),
                mode: .shadow,
                recorder: recorder,
                backend: recorder.backend(result: .empty),
                nonceGenerator: sequentialNonceGenerator(),
                legacy: { _ in recorder.legacyCalls += 1; throw TestError.legacy }
            )
        )
        XCTAssertEqual(recorder.legacyCalls, 1)
        XCTAssertEqual(recorder.nativeCalls, 0)
        XCTAssertTrue(recorder.diagnostics.isEmpty)
    }

    func testShadowUsesSameNamedNoncePlanReturnsExactLegacyAndLogsNoSecrets() throws {
        let recorder = RewrapRecorder()
        let source = try mixedSource()
        let token = TimestampSentinel()
        let legacy = CloudVaultDocumentRewrapResult(
            data: ["legacy": token, "uid": "secret-user", "key": oldKey],
            changedFields: ["legacy"]
        )
        var legacyPlan: [CloudVaultDocumentRewrapNonce] = []
        var nativePlan: [CloudVaultDocumentRewrapNonce] = []
        let result = try invoke(
            source,
            mode: .shadow,
            recorder: recorder,
            backend: recorder.backend { request, _, _, _ in
                nativePlan = request.noncePlan
                return .empty
            },
            nonceGenerator: sequentialNonceGenerator()
        ) { plan in
            recorder.legacyCalls += 1
            legacyPlan = plan
            return legacy
        }

        XCTAssertTrue(result.data["legacy"] as AnyObject === token)
        XCTAssertEqual(result.changedFields, legacy.changedFields)
        XCTAssertEqual(legacyPlan, nativePlan)
        XCTAssertEqual(recorder.nativeCalls, 1)
        XCTAssertEqual(recorder.legacyCalls, 1)
        XCTAssertEqual(recorder.diagnostics.count, 1)
        XCTAssertEqual(recorder.diagnostics[0].operation, "document_rewrap")
        XCTAssertEqual(recorder.diagnostics[0].category, "invalid_result")
        XCTAssertFalse(String(describing: recorder.diagnostics).contains("secret-user"))
        XCTAssertFalse(String(describing: recorder.diagnostics).contains(oldKey.base64EncodedString()))
    }

    func testShadowExactCompleteResultEmitsNoMismatch() throws {
        let recorder = RewrapRecorder()
        let source = try mixedSource()
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        var expected: CloudVaultDocumentRewrapResult?
        let result = try invoke(
            source,
            mode: .shadow,
            recorder: recorder,
            backend: recorder.backend { request, _, _, _ in
                self.successResult(request: request, newVaultKeyID: newVaultKeyID)
            },
            nonceGenerator: sequentialNonceGenerator()
        ) { plan in
            recorder.legacyCalls += 1
            let request = self.requestForExpected(source: source, noncePlan: plan)
            let native = self.successResult(request: request, newVaultKeyID: newVaultKeyID)
            expected = try self.applyExpected(native, source: source, request: request, newVaultKeyID: newVaultKeyID)
            return try XCTUnwrap(expected)
        }

        XCTAssertEqual(result.changedFields, expected?.changedFields)
        XCTAssertTrue(recorder.diagnostics.isEmpty)
        XCTAssertEqual(recorder.nativeCalls, 1)
        XCTAssertEqual(recorder.legacyCalls, 1)
    }

    func testRustFailsClosedWithoutLegacyForUnavailableABIInputNativeAndResultFailures() throws {
        let source = try mixedSource()
        let scenarios: [(CloudVaultDocumentRewrapDomainCoreAdapter.NativeBackend?, Data, Data)] = [
            (nil, oldKey, newKey),
            (RewrapRecorder().backend(result: .empty, abi: 99), oldKey, newKey),
            (RewrapRecorder().backend { _, _, _, _ in throw TestError.native }, oldKey, newKey),
            (RewrapRecorder().backend(result: .empty), oldKey, newKey),
            (RewrapRecorder().backend(result: .empty), oldKey, oldKey)
        ]
        for (backend, oldKey, newKey) in scenarios {
            let recorder = RewrapRecorder()
            XCTAssertThrowsError(
                try invoke(
                    source,
                    mode: .rust,
                    recorder: recorder,
                    backend: backend,
                    oldKey: oldKey,
                    newKey: newKey,
                    newVaultKeyID: try CloudVaultCrypto.vaultKeyID(for: newKey),
                    nonceGenerator: sequentialNonceGenerator(),
                    legacy: { _ in recorder.legacyCalls += 1; throw TestError.legacy }
                )
            )
            XCTAssertEqual(recorder.legacyCalls, 0)
        }
    }

    func testShadowABIMismatchDoesNotQueryCoreVersionOrNative() throws {
        let recorder = RewrapRecorder()
        var coreVersionCalls = 0
        var nativeCalls = 0
        let backend = CloudVaultDocumentRewrapDomainCoreAdapter.NativeBackend(
            abiVersion: { 99 },
            coreVersion: { coreVersionCalls += 1; return "must-not-load" },
            rewrap: { _, _, _, _ in nativeCalls += 1; return .empty }
        )

        _ = try invoke(
            try mixedSource(),
            mode: .shadow,
            recorder: recorder,
            backend: backend,
            nonceGenerator: sequentialNonceGenerator(),
            legacy: { _ in
                recorder.legacyCalls += 1
                return .init(data: ["legacy": true], changedFields: [])
            }
        )

        XCTAssertEqual(recorder.legacyCalls, 1)
        XCTAssertEqual(nativeCalls, 0)
        XCTAssertEqual(coreVersionCalls, 0)
        XCTAssertEqual(recorder.diagnostics.map(\.category), ["abi_mismatch"])
        XCTAssertEqual(recorder.diagnostics.map(\.coreVersion), ["incompatible"])
    }

    func testRustRejectsOutputThatDoesNotUseNamedNoncePlan() throws {
        let recorder = RewrapRecorder()
        XCTAssertThrowsError(
            try invoke(
                try mixedSource(),
                mode: .rust,
                recorder: recorder,
                backend: recorder.backend { request, _, _, keyID in
                    self.successResult(
                        request: request,
                        newVaultKeyID: keyID,
                        nonceOverrides: ["sealedTextZ": Data(repeating: 0xff, count: 12)]
                    )
                },
                nonceGenerator: sequentialNonceGenerator(),
                legacy: { _ in recorder.legacyCalls += 1; throw TestError.legacy }
            )
        )
        XCTAssertEqual(recorder.nativeCalls, 1)
        XCTAssertEqual(recorder.legacyCalls, 0)
    }

    func testDuplicateNoncePlanRejectsBeforeLegacyOrNative() throws {
        let recorder = RewrapRecorder()
        XCTAssertThrowsError(
            try invoke(
                try mixedSource(),
                mode: .rust,
                recorder: recorder,
                backend: recorder.backend(result: .empty),
                nonceGenerator: { Data(repeating: 0x55, count: 12) },
                legacy: { _ in recorder.legacyCalls += 1; throw TestError.legacy }
            )
        )
        XCTAssertEqual(recorder.nativeCalls, 0)
        XCTAssertEqual(recorder.legacyCalls, 0)
    }

    #if canImport(OpenBurnBarDomainCoreFFI)
    func testProductionBackendMatchesCanonicalMixedDocumentFixture() throws {
        let fixture = try Self.loadFixture()
        let oldKey = try Self.data(hex: fixture.oldKeyHex)
        let newKey = try Self.data(hex: fixture.newKeyHex)
        let createdAt = TimestampSentinel()
        var document: [String: Any] = Dictionary(
            uniqueKeysWithValues: fixture.request.documentFieldNames.map { ($0, "plain" as Any) }
        )
        for envelope in fixture.request.envelopes {
            document[envelope.fieldName] = envelope.map(createdAt: createdAt)
        }
        document["plainStatus"] = "queued"
        document["vaultKeyID"] = try CloudVaultCrypto.vaultKeyID(for: oldKey)
        var nonces = fixture.request.resealNoncePlan.map { Data($0.nonce) }

        let result = try CloudVaultDocumentRewrapDomainCoreAdapter.rewrap(
            data: document,
            uid: fixture.request.uid,
            collection: fixture.request.collection,
            docID: fixture.request.docID,
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: fixture.newVaultKeyID,
            vaultGeneration: fixture.request.vaultGeneration,
            rotationJobID: fixture.request.rotationJobID,
            mode: .rust,
            logger: RewrapRecorder(),
            backend: try XCTUnwrap(CloudVaultDocumentRewrapDomainCoreAdapter.productionBackend),
            nonceGenerator: { nonces.removeFirst() },
            legacy: { _ in XCTFail("Rust mode evaluated legacy"); throw TestError.legacy }
        )

        XCTAssertEqual(result.changedFields, fixture.expected.changedFields)
        let blobField = try XCTUnwrap(fixture.request.envelopes.first { $0.kind == "blob" }?.fieldName)
        XCTAssertTrue(
            (result.data[blobField] as? [String: Any])?["createdAt"] as AnyObject? === createdAt
        )
    }
    #endif

    private func invoke(
        _ source: [String: Any],
        mode: CloudVaultDocumentRewrapMigrationMode,
        recorder: RewrapRecorder,
        backend: CloudVaultDocumentRewrapDomainCoreAdapter.NativeBackend?,
        oldKey: Data? = nil,
        newKey: Data? = nil,
        newVaultKeyID: String? = nil,
        vaultGeneration: Int? = nil,
        rotationJobID: String? = nil,
        nonceGenerator: @escaping () throws -> Data,
        legacy: ([CloudVaultDocumentRewrapNonce]) throws -> CloudVaultDocumentRewrapResult
    ) throws -> CloudVaultDocumentRewrapResult {
        let oldKey = oldKey ?? self.oldKey
        let newKey = newKey ?? self.newKey
        return try CloudVaultDocumentRewrapDomainCoreAdapter.rewrap(
            data: source,
            uid: "userA",
            collection: "collectionA",
            docID: "docA",
            oldKeyData: oldKey,
            newKeyData: newKey,
            newVaultKeyID: try newVaultKeyID ?? CloudVaultCrypto.vaultKeyID(for: newKey),
            vaultGeneration: vaultGeneration,
            rotationJobID: rotationJobID,
            mode: mode,
            logger: recorder,
            backend: backend,
            nonceGenerator: nonceGenerator,
            legacy: legacy
        )
    }

    private func mixedSource(createdAt: Any = Date(timeIntervalSince1970: 1_800_000_000)) throws -> [String: Any] {
        [
            "sealedTextZ": try CloudVaultCrypto.firestoreDictionary(
                CloudVaultCrypto.sealText("label", keyData: oldKey)
            ),
            "plainStatus": "queued",
            "sealedBlobA": try blobMap(key: oldKey, createdAt: createdAt),
            "vaultKeyID": try CloudVaultCrypto.vaultKeyID(for: oldKey),
            "sealedPayload": try payloadMap(key: oldKey)
        ]
    }

    private func payloadMap(key: Data) throws -> [String: Any] {
        try CloudVaultCrypto.firestoreDictionary(
            CloudVaultCrypto.sealPayload(
                Data("payload".utf8),
                keyData: key,
                vaultKeyID: CloudVaultCrypto.vaultKeyID(for: key)
            )
        )
    }

    private func blobMap(key: Data, createdAt: Any) throws -> [String: Any] {
        var map = try CloudVaultCrypto.firestoreDictionary(
            CloudVaultCrypto.sealBlob(Data("blob".utf8), keyData: key)
        )
        map["createdAt"] = createdAt
        return map
    }

    private func successResult(
        request: CloudVaultDocumentRewrapDomainCoreAdapter.Request,
        newVaultKeyID: String,
        nonceOverrides: [String: Data] = [:]
    ) -> CloudVaultDocumentRewrapDomainCoreAdapter.NativeResult {
        let outputs = request.envelopes.map { envelope in
            outputEnvelope(
                envelope,
                request: request,
                newVaultKeyID: newVaultKeyID,
                nonceOverride: nonceOverrides[envelope.fieldName]
            )
        }
        return .init(
            changedFields: outputs.map(\.fieldName),
            skippedFields: [],
            rewrappedEnvelopes: outputs,
            companionIntents: [
                .init(sourceFieldName: "sealedPayload", companionFieldName: "vaultKeyID", vaultKeyID: newVaultKeyID)
            ],
            preservedMemberIntents: [
                .init(sourceFieldName: "sealedBlobA", memberName: "createdAt")
            ],
            vaultGenerationUpdate: request.vaultGeneration,
            rotationJobIDUpdate: request.rotationJobID
        )
    }

    private func outputEnvelope(
        _ source: CloudVaultDocumentRewrapDomainCoreAdapter.Envelope,
        request: CloudVaultDocumentRewrapDomainCoreAdapter.Request,
        newVaultKeyID: String,
        nonceOverride: Data? = nil
    ) -> CloudVaultDocumentRewrapDomainCoreAdapter.Envelope {
        let aad = "OpenBurnBar-CloudVault-aad-v2|\(request.uid)|\(request.collection)|\(request.docID)|\(source.fieldName)|2|\(source.fieldName)"
        let plannedNonce = request.noncePlan.first { $0.fieldName == source.fieldName }!.bytes
        let outputNonce = nonceOverride ?? plannedNonce
        let combined = outputNonce + Data(repeating: 0x23, count: 17)
        return .init(
            kind: source.kind,
            fieldName: source.fieldName,
            schemaVersion: 2,
            algorithm: CloudVaultCrypto.aesGCMAlgorithm,
            keyVersion: 1,
            vaultKeyID: source.kind == .sealedPayload ? newVaultKeyID : nil,
            nonce: source.kind == .sealedText ? outputNonce.base64EncodedString() : nil,
            ciphertext: source.kind == .sealedText ? "bmV3" : nil,
            tag: source.kind == .sealedText ? "IiIiIiIiIiIiIiIiIiIiIg==" : nil,
            sealedBoxBase64: source.kind == .sealedText ? nil : combined.base64EncodedString(),
            plaintextSHA256: nil,
            plaintextHMAC: source.kind == .blob ? String(repeating: "a", count: 64) : nil,
            integrityHashVersion: source.kind == .blob ? 1 : nil,
            aad: aad,
            hasCreatedAt: source.kind == .blob && source.hasCreatedAt
        )
    }

    private func requestForExpected(
        source: [String: Any],
        noncePlan: [CloudVaultDocumentRewrapNonce]
    ) -> CloudVaultDocumentRewrapDomainCoreAdapter.Request {
        let fields = ["sealedBlobA", "sealedPayload", "sealedTextZ"]
        let kinds: [CloudVaultDocumentRewrapDomainCoreAdapter.Envelope.Kind] = [.blob, .sealedPayload, .sealedText]
        return .init(
            uid: "userA",
            collection: "collectionA",
            docID: "docA",
            documentFieldNames: source.keys.sorted(),
            envelopes: zip(fields, kinds).map { field, kind in
                .init(
                    kind: kind,
                    fieldName: field,
                    schemaVersion: 2,
                    algorithm: CloudVaultCrypto.aesGCMAlgorithm,
                    keyVersion: 1,
                    vaultKeyID: kind == .sealedPayload ? "old" : nil,
                    nonce: kind == .sealedText ? "old" : nil,
                    ciphertext: kind == .sealedText ? "old" : nil,
                    tag: kind == .sealedText ? "old" : nil,
                    sealedBoxBase64: kind == .sealedText ? nil : "old",
                    plaintextSHA256: nil,
                    plaintextHMAC: kind == .blob ? "old" : nil,
                    integrityHashVersion: kind == .blob ? 1 : nil,
                    aad: "old",
                    hasCreatedAt: kind == .blob
                )
            },
            noncePlan: noncePlan,
            vaultGeneration: nil,
            rotationJobID: nil
        )
    }

    private func applyExpected(
        _ native: CloudVaultDocumentRewrapDomainCoreAdapter.NativeResult,
        source: [String: Any],
        request: CloudVaultDocumentRewrapDomainCoreAdapter.Request,
        newVaultKeyID: String
    ) throws -> CloudVaultDocumentRewrapResult {
        var data = source
        for envelope in native.rewrappedEnvelopes {
            var map: [String: Any] = [
                "schemaVersion": 2,
                "algorithm": envelope.algorithm,
                "keyVersion": 1,
                "aad": envelope.aad as Any
            ]
            if let value = envelope.vaultKeyID { map["vaultKeyID"] = value }
            if let value = envelope.nonce { map["nonce"] = value }
            if let value = envelope.ciphertext { map["ciphertext"] = value }
            if let value = envelope.tag { map["tag"] = value }
            if let value = envelope.sealedBoxBase64 { map["sealedBoxBase64"] = value }
            if let value = envelope.plaintextHMAC { map["plaintextHMAC"] = value }
            if let value = envelope.integrityHashVersion { map["integrityHashVersion"] = Int(value) }
            if envelope.hasCreatedAt {
                map["createdAt"] = (source[envelope.fieldName] as? [String: Any])?["createdAt"]
            }
            data[envelope.fieldName] = map
        }
        data["vaultKeyID"] = newVaultKeyID
        return .init(data: data, changedFields: native.changedFields)
    }

    private func sequentialNonceGenerator() -> () throws -> Data {
        var byte: UInt8 = 0x10
        return {
            byte += 1
            return Data(repeating: byte, count: 12)
        }
    }

    #if canImport(OpenBurnBarDomainCoreFFI)
    private static func loadFixture() throws -> RewrapFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../tests/fixtures/domain-core/cloudvault/v1/cloudvault-document-rewrap-contract.json")
            .standardizedFileURL
        return try JSONDecoder().decode(RewrapFixture.self, from: Data(contentsOf: url))
    }

    private static func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw TestError.fixture }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw TestError.fixture }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
    #endif
}

private final class RewrapRecorder: CloudVaultDocumentRewrapLogging {
    var nativeCalls = 0
    var legacyCalls = 0
    var diagnostics: [CloudVaultDocumentRewrapDiagnostic] = []

    func log(_ diagnostic: CloudVaultDocumentRewrapDiagnostic) {
        diagnostics.append(diagnostic)
    }

    func backend(
        result: CloudVaultDocumentRewrapDomainCoreAdapter.NativeResult,
        abi: UInt32 = CloudVaultDocumentRewrapDomainCoreAdapter.requiredABIVersion
    ) -> CloudVaultDocumentRewrapDomainCoreAdapter.NativeBackend {
        backend(abi: abi) { _, _, _, _ in result }
    }

    func backend(
        abi: UInt32 = CloudVaultDocumentRewrapDomainCoreAdapter.requiredABIVersion,
        rewrap: @escaping (
            CloudVaultDocumentRewrapDomainCoreAdapter.Request,
            Data,
            Data,
            String
        ) throws -> CloudVaultDocumentRewrapDomainCoreAdapter.NativeResult
    ) -> CloudVaultDocumentRewrapDomainCoreAdapter.NativeBackend {
        .init(
            abiVersion: { abi },
            coreVersion: { "test-core" },
            rewrap: { request, oldKey, newKey, newVaultKeyID in
                self.nativeCalls += 1
                return try rewrap(request, oldKey, newKey, newVaultKeyID)
            }
        )
    }
}

private final class TimestampSentinel {}

private enum TestError: Error {
    case legacy
    case native
    case fixture
}

private extension CloudVaultDocumentRewrapDomainCoreAdapter.NativeResult {
    static let empty = Self(
        changedFields: [],
        skippedFields: [],
        rewrappedEnvelopes: [],
        companionIntents: [],
        preservedMemberIntents: [],
        vaultGenerationUpdate: nil,
        rotationJobIDUpdate: nil
    )
}

#if canImport(OpenBurnBarDomainCoreFFI)
private struct RewrapFixture: Decodable {
    let oldKeyHex: String
    let newKeyHex: String
    let newVaultKeyID: String
    let request: FixtureRequest
    let expected: FixtureExpected
}

private struct FixtureRequest: Decodable {
    let uid: String
    let collection: String
    let docID: String
    let documentFieldNames: [String]
    let envelopes: [FixtureEnvelope]
    let resealNoncePlan: [FixtureNonce]
    let vaultGeneration: Int?
    let rotationJobID: String?

    enum CodingKeys: String, CodingKey {
        case uid, collection, documentFieldNames, envelopes, resealNoncePlan, vaultGeneration
        case docID = "docId"
        case rotationJobID = "rotationJobId"
    }
}

private struct FixtureNonce: Decodable {
    let fieldName: String
    let nonce: [UInt8]
}

private struct FixtureExpected: Decodable {
    let changedFields: [String]
}

private struct FixtureEnvelope: Decodable {
    let kind: String
    let fieldName: String
    let schemaVersion: UInt32?
    let algorithm: String
    let keyVersion: UInt32
    let vaultKeyID: String?
    let nonce: String?
    let ciphertext: String?
    let tag: String?
    let sealedBoxBase64: String?
    let plaintextSHA256: String?
    let plaintextHMAC: String?
    let integrityHashVersion: UInt32?
    let aad: String?
    let hasCreatedAt: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, fieldName, schemaVersion, algorithm, keyVersion, nonce, ciphertext, tag
        case sealedBoxBase64, integrityHashVersion, aad, hasCreatedAt
        case vaultKeyID = "vaultKeyId"
        case plaintextSHA256 = "plaintextSha256"
        case plaintextHMAC = "plaintextHmac"
    }

    func map(createdAt: Any) -> [String: Any] {
        var map: [String: Any] = ["algorithm": algorithm, "keyVersion": Int(keyVersion)]
        if let value = schemaVersion { map["schemaVersion"] = Int(value) }
        if let value = vaultKeyID { map["vaultKeyID"] = value }
        if let value = nonce { map["nonce"] = value }
        if let value = ciphertext { map["ciphertext"] = value }
        if let value = tag { map["tag"] = value }
        if let value = sealedBoxBase64 { map["sealedBoxBase64"] = value }
        if let value = plaintextSHA256 { map["plaintextSHA256"] = value }
        if let value = plaintextHMAC { map["plaintextHMAC"] = value }
        if let value = integrityHashVersion { map["integrityHashVersion"] = Int(value) }
        if let value = aad { map["aad"] = value }
        if hasCreatedAt == true { map["createdAt"] = createdAt }
        return map
    }
}
#endif
