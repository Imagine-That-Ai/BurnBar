import Foundation
import OpenBurnBarKernel
#if canImport(CoreFoundation)
import CoreFoundation
#endif

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum CloudVaultDocumentRewrapMigrationMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static let environmentKey = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE"

    static func resolve(environment: [String: String]) -> Self {
        Self(rawValue: DomainCoreBuildProfileResolver.mode(for: .cloudVaultRewrap, environment: environment).rawValue) ?? .legacy
    }
}

struct CloudVaultDocumentRewrapNonce: Equatable, Sendable {
    let fieldName: String
    let bytes: Data
}

struct CloudVaultDocumentRewrapDiagnostic: Equatable, Sendable {
    let operation: String
    let category: String
    let coreVersion: String
    let count: UInt64
}

protocol CloudVaultDocumentRewrapLogging {
    func log(_ diagnostic: CloudVaultDocumentRewrapDiagnostic)
}

struct PlatformCloudVaultDocumentRewrapLogger: CloudVaultDocumentRewrapLogging {
    private let logger = PlatformLogger(
        subsystem: "com.openburnbar.core",
        category: "CloudVaultDocumentRewrapDomainCore"
    )

    func log(_ diagnostic: CloudVaultDocumentRewrapDiagnostic) {
        logger.warning(
            "operation=\(diagnostic.operation) category=\(diagnostic.category) "
                + "core_version=\(diagnostic.coreVersion) count=\(diagnostic.count)"
        )
    }
}

enum CloudVaultDocumentRewrapAdapterError: Error, Equatable {
    case nativeUnavailable
    case abiMismatch
    case invalidInput
    case invalidResult
    case nativeFailure
}

enum CloudVaultDocumentRewrapDomainCoreAdapter {
    static let requiredABIVersion: UInt32 = 3
    static let operation = "document_rewrap"

    struct Envelope: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case sealedPayload
            case sealedText
            case blob
        }

        let kind: Kind
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
        let hasCreatedAt: Bool
    }

    struct Request: Equatable, Sendable {
        let uid: String
        let collection: String
        let docID: String
        let documentFieldNames: [String]
        let envelopes: [Envelope]
        let noncePlan: [CloudVaultDocumentRewrapNonce]
        let vaultGeneration: Int64?
        let rotationJobID: String?
    }

    struct CompanionIntent: Equatable, Hashable, Sendable {
        let sourceFieldName: String
        let companionFieldName: String
        let vaultKeyID: String
    }

    struct PreservedMemberIntent: Equatable, Hashable, Sendable {
        let sourceFieldName: String
        let memberName: String
    }

    struct NativeResult: Equatable, Sendable {
        let changedFields: [String]
        let skippedFields: [String]
        let rewrappedEnvelopes: [Envelope]
        let companionIntents: [CompanionIntent]
        let preservedMemberIntents: [PreservedMemberIntent]
        let vaultGenerationUpdate: Int64?
        let rotationJobIDUpdate: String?
    }

    struct NativeBackend {
        let abiVersion: () -> UInt32
        let coreVersion: () -> String
        let rewrap: (_ request: Request, _ oldKey: Data, _ newKey: Data, _ newVaultKeyID: String) throws -> NativeResult
    }

    static var productionBackend: NativeBackend? {
        #if canImport(OpenBurnBarDomainCoreFFI)
        NativeBackend(
            abiVersion: { DomainCoreNativeProbe.abiVersion() ?? 0 },
            coreVersion: { OpenBurnBarDomainCoreFFI.domainCoreVersion() },
            rewrap: { request, oldKey, newKey, newVaultKeyID in
                let result = try OpenBurnBarDomainCoreFFI.cloudVaultRewrapDocument(
                    request: .init(
                        uid: request.uid,
                        collection: request.collection,
                        docId: request.docID,
                        documentFieldNames: request.documentFieldNames,
                        envelopes: request.envelopes.map(ffiEnvelope),
                        resealNoncePlan: request.noncePlan.map {
                            CloudVaultResealNonce(fieldName: $0.fieldName, nonce: $0.bytes)
                        },
                        vaultGeneration: request.vaultGeneration,
                        rotationJobId: request.rotationJobID
                    ),
                    oldKey: oldKey,
                    newKey: newKey,
                    newVaultKeyId: newVaultKeyID
                )
                return NativeResult(
                    changedFields: result.changedFields,
                    skippedFields: result.skippedFields,
                    rewrappedEnvelopes: result.rewrappedEnvelopes.map(nativeEnvelope),
                    companionIntents: result.companionUpdateIntents.map {
                        CompanionIntent(
                            sourceFieldName: $0.sourceFieldName,
                            companionFieldName: $0.companionFieldName,
                            vaultKeyID: $0.vaultKeyId
                        )
                    },
                    preservedMemberIntents: result.preservedMemberIntents.map {
                        PreservedMemberIntent(sourceFieldName: $0.sourceFieldName, memberName: $0.memberName)
                    },
                    vaultGenerationUpdate: result.vaultGenerationUpdate,
                    rotationJobIDUpdate: result.rotationJobIdUpdate
                )
            }
        )
        #else
        nil
        #endif
    }

    static func rewrap(
        data: [String: Any],
        uid: String,
        collection: String,
        docID: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobID: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDocumentRewrapLogging = PlatformCloudVaultDocumentRewrapLogger(),
        backend: NativeBackend? = productionBackend,
        nonceGenerator: () throws -> Data = CloudVaultCrypto.generateDocumentRewrapNonce,
        legacy: ([CloudVaultDocumentRewrapNonce]) throws -> CloudVaultDocumentRewrapResult
    ) throws -> CloudVaultDocumentRewrapResult {
        let mode = CloudVaultDocumentRewrapMigrationMode.resolve(environment: environment)
        return try rewrap(
            data: data,
            uid: uid,
            collection: collection,
            docID: docID,
            oldKeyData: oldKeyData,
            newKeyData: newKeyData,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: vaultGeneration,
            rotationJobID: rotationJobID,
            mode: mode,
            logger: logger,
            backend: backend,
            nonceGenerator: nonceGenerator,
            legacy: legacy
        )
    }

    static func rewrap(
        data: [String: Any],
        uid: String,
        collection: String,
        docID: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobID: String?,
        mode: CloudVaultDocumentRewrapMigrationMode,
        logger: any CloudVaultDocumentRewrapLogging,
        backend: NativeBackend?,
        nonceGenerator: () throws -> Data,
        legacy: ([CloudVaultDocumentRewrapNonce]) throws -> CloudVaultDocumentRewrapResult
    ) throws -> CloudVaultDocumentRewrapResult {
        if mode == .legacy {
            return try legacy(
                makeLegacyNoncePlan(
                    data: data,
                    newVaultKeyID: newVaultKeyID,
                    generator: nonceGenerator
                )
            )
        }

        if mode == .shadow {
            let legacyNoncePlan = try makeLegacyNoncePlan(
                data: data,
                newVaultKeyID: newVaultKeyID,
                generator: nonceGenerator
            )
            let legacyStarted = Date.timeIntervalSinceReferenceDate
            let legacyResult = try legacy(legacyNoncePlan)
            let legacyMicros = elapsedMicros(since: legacyStarted)
            let rustStarted = Date.timeIntervalSinceReferenceDate
            var matches = false
            var mismatchCategory: String? = "native_error"
            do {
                let envelopes = try lowerEnvelopes(data)
                var nonceIndex = 0
                let noncePlan = try makeNoncePlan(
                    envelopes: envelopes,
                    newVaultKeyID: newVaultKeyID
                ) {
                    guard legacyNoncePlan.indices.contains(nonceIndex) else {
                        throw CloudVaultDocumentRewrapAdapterError.invalidInput
                    }
                    defer { nonceIndex += 1 }
                    return legacyNoncePlan[nonceIndex].bytes
                }
                guard noncePlan.map(\.fieldName) == legacyNoncePlan.map(\.fieldName),
                      nonceIndex == legacyNoncePlan.count else {
                    throw CloudVaultDocumentRewrapAdapterError.invalidInput
                }
                let rustResult = try rustRewrap(
                    data: data,
                    uid: uid,
                    collection: collection,
                    docID: docID,
                    oldKeyData: oldKeyData,
                    newKeyData: newKeyData,
                    newVaultKeyID: newVaultKeyID,
                    vaultGeneration: vaultGeneration,
                    rotationJobID: rotationJobID,
                    envelopes: envelopes,
                    noncePlan: noncePlan,
                    backend: backend
                )
                matches = equivalent(legacyResult, rustResult)
                mismatchCategory = matches ? nil : "result_mismatch"
                if !matches {
                    emit(category: "value_mismatch", backend: backend, logger: logger)
                }
            } catch let error as CloudVaultDocumentRewrapAdapterError {
                emit(category: diagnosticCategory(for: error), backend: backend, logger: logger)
                mismatchCategory = error == .nativeUnavailable || error == .abiMismatch
                    ? "native_unavailable"
                    : "invalid_result"
            } catch {
                emit(category: "native_error", backend: backend, logger: logger)
            }
            DomainCoreShadowComparisonCollector.record(.init(
                domain: "cloudvault",
                slice: "document-rewrap",
                operation: "document_rewrap",
                coreVersion: backend?.coreVersion() ?? "0.0.0-native-unavailable",
                outcome: matches ? "match" : "mismatch",
                mismatchCategory: mismatchCategory,
                legacyMicros: legacyMicros,
                rustMicros: elapsedMicros(since: rustStarted)
            ))
            return legacyResult
        }

        let envelopes = try lowerEnvelopes(data)
        let noncePlan = try makeNoncePlan(
            envelopes: envelopes,
            newVaultKeyID: newVaultKeyID,
            generator: nonceGenerator
        )

        return try rustRewrap(
            data: data,
            uid: uid,
            collection: collection,
            docID: docID,
            oldKeyData: oldKeyData,
            newKeyData: newKeyData,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: vaultGeneration,
            rotationJobID: rotationJobID,
            envelopes: envelopes,
            noncePlan: noncePlan,
            backend: backend
        )
    }

    private static func elapsedMicros(since started: TimeInterval) -> UInt64 {
        UInt64(min(600_000_000, max(0, ((Date.timeIntervalSinceReferenceDate - started) * 1_000_000).rounded())))
    }

    private static func rustRewrap(
        data: [String: Any],
        uid: String,
        collection: String,
        docID: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobID: String?,
        envelopes: [Envelope],
        noncePlan: [CloudVaultDocumentRewrapNonce],
        backend: NativeBackend?
    ) throws -> CloudVaultDocumentRewrapResult {
        let generation = try exactInt64(vaultGeneration)
        guard oldKeyData.count == 32,
              newKeyData.count == 32,
              oldKeyData != newKeyData,
              platformVaultKeyID(oldKeyData) != newVaultKeyID,
              platformVaultKeyID(newKeyData) == newVaultKeyID else {
            throw CloudVaultDocumentRewrapAdapterError.invalidInput
        }
        guard let backend else { throw CloudVaultDocumentRewrapAdapterError.nativeUnavailable }
        guard backend.abiVersion() == requiredABIVersion else {
            throw CloudVaultDocumentRewrapAdapterError.abiMismatch
        }

        let request = Request(
            uid: uid,
            collection: collection,
            docID: docID,
            documentFieldNames: data.keys.sorted(),
            envelopes: envelopes,
            noncePlan: noncePlan,
            vaultGeneration: generation,
            rotationJobID: rotationJobID
        )
        let nativeResult: NativeResult
        do {
            nativeResult = try backend.rewrap(request, oldKeyData, newKeyData, newVaultKeyID)
        } catch let error as CloudVaultDocumentRewrapAdapterError {
            throw error
        } catch {
            throw CloudVaultDocumentRewrapAdapterError.nativeFailure
        }
        return try apply(
            nativeResult,
            to: data,
            request: request,
            newVaultKeyID: newVaultKeyID
        )
    }

    private static func lowerEnvelopes(_ data: [String: Any]) throws -> [Envelope] {
        try data.compactMap { field, value -> Envelope? in
            guard let raw = value as? [String: Any] else { return nil }
            return try lowerEnvelope(field: field, raw: raw)
        }.sorted { $0.fieldName < $1.fieldName }
    }

    private static func lowerEnvelope(field: String, raw: [String: Any]) throws -> Envelope? {
        let rawKeys = Set(raw.keys)
        let payloadCandidate = rawKeys.contains("vaultKeyID")
        let textCandidate = !rawKeys.isDisjoint(with: ["nonce", "ciphertext", "tag"])
        let blobMarkers: Set<String> = ["plaintextSHA256", "plaintextHMAC", "integrityHashVersion", "createdAt"]
        let blobCandidate = rawKeys.contains("sealedBoxBase64")
            && (!payloadCandidate || !rawKeys.isDisjoint(with: blobMarkers))
        let candidateCount = [payloadCandidate, textCandidate, blobCandidate].filter { $0 }.count
        guard candidateCount <= 1 else { throw CloudVaultDocumentRewrapAdapterError.invalidInput }
        guard candidateCount == 1 else { return nil }

        let reservedTopLevelFields: Set<String> = [
            "vaultKeyID",
            "sealedStateVaultKeyID",
            "vaultGeneration",
            "rewrapJobId",
            "rewrapJobID",
            "rotationJobId",
            "rotationJobID"
        ]
        guard !reservedTopLevelFields.contains(field) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidInput
        }

        let common: Set<String> = ["schemaVersion", "algorithm", "keyVersion", "aad"]
        let payloadMembers = common.union(["vaultKeyID", "sealedBoxBase64"])
        let textMembers = common.union(["nonce", "ciphertext", "tag"])
        let blobMembers = common.union(blobMarkers).union(["sealedBoxBase64"])
        let allowed = payloadCandidate ? payloadMembers : (textCandidate ? textMembers : blobMembers)
        guard rawKeys.isSubset(of: allowed) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidInput
        }

        let algorithm = try requiredString(raw, "algorithm")
        let keyVersion = try requiredUInt32(raw, "keyVersion")
        if payloadCandidate {
            return Envelope(
                kind: .sealedPayload,
                fieldName: field,
                schemaVersion: try requiredUInt32(raw, "schemaVersion"),
                algorithm: algorithm,
                keyVersion: keyVersion,
                vaultKeyID: try requiredString(raw, "vaultKeyID"),
                nonce: nil,
                ciphertext: nil,
                tag: nil,
                sealedBoxBase64: try requiredString(raw, "sealedBoxBase64"),
                plaintextSHA256: nil,
                plaintextHMAC: nil,
                integrityHashVersion: nil,
                aad: try optionalString(raw, "aad"),
                hasCreatedAt: false
            )
        }
        if textCandidate {
            return Envelope(
                kind: .sealedText,
                fieldName: field,
                schemaVersion: try optionalUInt32(raw, "schemaVersion"),
                algorithm: algorithm,
                keyVersion: keyVersion,
                vaultKeyID: nil,
                nonce: try requiredString(raw, "nonce"),
                ciphertext: try requiredString(raw, "ciphertext"),
                tag: try requiredString(raw, "tag"),
                sealedBoxBase64: nil,
                plaintextSHA256: nil,
                plaintextHMAC: nil,
                integrityHashVersion: nil,
                aad: try optionalString(raw, "aad"),
                hasCreatedAt: false
            )
        }
        return Envelope(
            kind: .blob,
            fieldName: field,
            schemaVersion: try requiredUInt32(raw, "schemaVersion"),
            algorithm: algorithm,
            keyVersion: keyVersion,
            vaultKeyID: nil,
            nonce: nil,
            ciphertext: nil,
            tag: nil,
            sealedBoxBase64: try requiredString(raw, "sealedBoxBase64"),
            plaintextSHA256: try optionalString(raw, "plaintextSHA256"),
            plaintextHMAC: try optionalString(raw, "plaintextHMAC"),
            integrityHashVersion: try optionalUInt32(raw, "integrityHashVersion"),
            aad: try optionalString(raw, "aad"),
            hasCreatedAt: raw.keys.contains("createdAt")
        )
    }

    private static func makeNoncePlan(
        envelopes: [Envelope],
        newVaultKeyID: String,
        generator: () throws -> Data
    ) throws -> [CloudVaultDocumentRewrapNonce] {
        var seen = Set<Data>()
        return try envelopes.compactMap { envelope in
            if envelope.kind == .sealedPayload, envelope.vaultKeyID == newVaultKeyID {
                return nil
            }
            let nonce = try generator()
            guard nonce.count == 12, seen.insert(nonce).inserted else {
                throw CloudVaultDocumentRewrapAdapterError.invalidInput
            }
            return CloudVaultDocumentRewrapNonce(fieldName: envelope.fieldName, bytes: nonce)
        }
    }

    private static func makeLegacyNoncePlan(
        data: [String: Any],
        newVaultKeyID: String,
        generator: () throws -> Data
    ) rethrows -> [CloudVaultDocumentRewrapNonce] {
        try data.keys.sorted().compactMap { field in
            guard let raw = data[field] as? [String: Any] else { return nil }
            if let payload = CloudVaultCrypto.sealedPayload(from: raw) {
                guard payload.vaultKeyID != newVaultKeyID else { return nil }
                return CloudVaultDocumentRewrapNonce(fieldName: field, bytes: try generator())
            }
            if CloudVaultCrypto.decodeSealedText(from: raw) != nil
                || CloudVaultCrypto.decodeBlobEnvelopeForDocumentRewrap(raw) != nil {
                return CloudVaultDocumentRewrapNonce(fieldName: field, bytes: try generator())
            }
            return nil
        }
    }

    private static func apply(
        _ result: NativeResult,
        to data: [String: Any],
        request: Request,
        newVaultKeyID: String
    ) throws -> CloudVaultDocumentRewrapResult {
        let changed = result.changedFields
        let skipped = result.skippedFields
        guard changed == changed.sorted(),
              skipped == skipped.sorted(),
              Set(changed).count == changed.count,
              Set(skipped).count == skipped.count,
              Set(changed).isDisjoint(with: Set(skipped)),
              Set(changed).union(skipped) == Set(request.envelopes.map(\.fieldName)) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }

        let sourceByField = Dictionary(uniqueKeysWithValues: request.envelopes.map { ($0.fieldName, $0) })
        let noncePairs = request.noncePlan.map { ($0.fieldName, $0.bytes) }
        guard Dictionary(grouping: noncePairs, by: \.0).values.allSatisfy({ $0.count == 1 }) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }
        let nonceByField = Dictionary(uniqueKeysWithValues: noncePairs)
        guard Set(nonceByField.keys) == Set(changed) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }
        let outputPairs = result.rewrappedEnvelopes.map { ($0.fieldName, $0) }
        guard Dictionary(grouping: outputPairs, by: \.0).values.allSatisfy({ $0.count == 1 }) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }
        let outputByField = Dictionary(uniqueKeysWithValues: outputPairs)
        guard Set(outputByField.keys) == Set(changed) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }
        for field in changed {
            guard let source = sourceByField[field],
                  let output = outputByField[field],
                  let expectedNonce = nonceByField[field],
                  source.kind == output.kind,
                  source.hasCreatedAt == output.hasCreatedAt else {
                throw CloudVaultDocumentRewrapAdapterError.invalidResult
            }
            try validateOutput(
                output,
                request: request,
                newVaultKeyID: newVaultKeyID,
                expectedNonce: expectedNonce
            )
        }
        for field in skipped {
            guard let source = sourceByField[field],
                  source.kind == .sealedPayload,
                  source.vaultKeyID == newVaultKeyID else {
                throw CloudVaultDocumentRewrapAdapterError.invalidResult
            }
        }

        var expectedCompanionByTarget: [String: CompanionIntent] = [:]
        for field in changed.sorted() {
            let companion: String?
            switch field {
            case "sealedPayload" where data.keys.contains("vaultKeyID"),
                 "sealedReplyPayload" where data.keys.contains("vaultKeyID"):
                companion = "vaultKeyID"
            case "sealedStatePayload" where data.keys.contains("sealedStateVaultKeyID"):
                companion = "sealedStateVaultKeyID"
            default:
                companion = nil
            }
            guard let companion, expectedCompanionByTarget[companion] == nil else { continue }
            expectedCompanionByTarget[companion] = CompanionIntent(
                sourceFieldName: field,
                companionFieldName: companion,
                vaultKeyID: newVaultKeyID
            )
        }
        let expectedCompanions = Set(expectedCompanionByTarget.values)
        guard Set(result.companionIntents).count == result.companionIntents.count,
              Set(result.companionIntents) == expectedCompanions else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }

        let expectedPreserved = Set(changed.compactMap { field -> PreservedMemberIntent? in
            guard sourceByField[field]?.kind == .blob,
                  sourceByField[field]?.hasCreatedAt == true else { return nil }
            return PreservedMemberIntent(sourceFieldName: field, memberName: "createdAt")
        })
        guard Set(result.preservedMemberIntents).count == result.preservedMemberIntents.count,
              Set(result.preservedMemberIntents) == expectedPreserved else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }

        let expectedGeneration = changed.isEmpty ? nil : request.vaultGeneration
        let expectedJobID = changed.isEmpty ? nil : request.rotationJobID
        guard result.vaultGenerationUpdate == expectedGeneration,
              result.rotationJobIDUpdate == expectedJobID else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }

        var updated = data
        for field in changed {
            guard let output = outputByField[field] else {
                throw CloudVaultDocumentRewrapAdapterError.invalidResult
            }
            updated[field] = envelopeMap(output)
        }
        for intent in result.preservedMemberIntents {
            guard let sourceMap = data[intent.sourceFieldName] as? [String: Any],
                  let preserved = sourceMap[intent.memberName],
                  var outputMap = updated[intent.sourceFieldName] as? [String: Any] else {
                throw CloudVaultDocumentRewrapAdapterError.invalidResult
            }
            outputMap[intent.memberName] = preserved
            updated[intent.sourceFieldName] = outputMap
        }
        for intent in result.companionIntents {
            updated[intent.companionFieldName] = intent.vaultKeyID
        }
        if let generation = result.vaultGenerationUpdate {
            guard let exact = Int(exactly: generation) else {
                throw CloudVaultDocumentRewrapAdapterError.invalidResult
            }
            updated["vaultGeneration"] = exact
        }
        if let jobID = result.rotationJobIDUpdate {
            updated["rewrapJobId"] = jobID
        }
        return CloudVaultDocumentRewrapResult(data: updated, changedFields: changed)
    }

    private static func validateOutput(
        _ envelope: Envelope,
        request: Request,
        newVaultKeyID: String,
        expectedNonce: Data
    ) throws {
        let expectedAAD = try CloudVaultAADContext(
            uid: request.uid,
            collection: request.collection,
            docID: request.docID,
            field: envelope.fieldName
        ).stringValue
        guard envelope.schemaVersion == 2,
              envelope.algorithm == CloudVaultCrypto.aesGCMAlgorithm,
              envelope.keyVersion == 1,
              envelope.aad == expectedAAD else {
            throw CloudVaultDocumentRewrapAdapterError.invalidResult
        }
        switch envelope.kind {
        case .sealedPayload:
            guard envelope.vaultKeyID == newVaultKeyID,
                  let sealedBoxBase64 = envelope.sealedBoxBase64,
                  let sealedBox = canonicalBase64Data(sealedBoxBase64),
                  sealedBox.count >= 28,
                  sealedBox.prefix(12) == expectedNonce,
                  envelope.nonce == nil,
                  envelope.ciphertext == nil,
                  envelope.tag == nil,
                  envelope.plaintextSHA256 == nil,
                  envelope.plaintextHMAC == nil,
                  envelope.integrityHashVersion == nil,
                  envelope.hasCreatedAt == false else {
                throw CloudVaultDocumentRewrapAdapterError.invalidResult
            }
        case .sealedText:
            guard envelope.vaultKeyID == nil,
                  let nonce = envelope.nonce.flatMap(canonicalBase64Data),
                  nonce == expectedNonce,
                  envelope.ciphertext.flatMap(canonicalBase64Data) != nil,
                  envelope.tag.flatMap(canonicalBase64Data)?.count == 16,
                  envelope.sealedBoxBase64 == nil,
                  envelope.plaintextSHA256 == nil,
                  envelope.plaintextHMAC == nil,
                  envelope.integrityHashVersion == nil,
                  envelope.hasCreatedAt == false else {
                throw CloudVaultDocumentRewrapAdapterError.invalidResult
            }
        case .blob:
            guard envelope.vaultKeyID == nil,
                  envelope.nonce == nil,
                  envelope.ciphertext == nil,
                  envelope.tag == nil,
                  let sealedBoxBase64 = envelope.sealedBoxBase64,
                  let sealedBox = canonicalBase64Data(sealedBoxBase64),
                  sealedBox.count >= 28,
                  sealedBox.prefix(12) == expectedNonce,
                  envelope.plaintextSHA256 == nil,
                  envelope.plaintextHMAC != nil,
                  envelope.integrityHashVersion == 1 else {
                throw CloudVaultDocumentRewrapAdapterError.invalidResult
            }
        }
    }

    private static func canonicalBase64Data(_ value: String) -> Data? {
        guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else {
            return nil
        }
        return data
    }

    private static func envelopeMap(_ envelope: Envelope) -> [String: Any] {
        var map: [String: Any] = [
            "algorithm": envelope.algorithm,
            "keyVersion": Int(envelope.keyVersion)
        ]
        if let value = envelope.schemaVersion { map["schemaVersion"] = Int(value) }
        if let value = envelope.vaultKeyID { map["vaultKeyID"] = value }
        if let value = envelope.nonce { map["nonce"] = value }
        if let value = envelope.ciphertext { map["ciphertext"] = value }
        if let value = envelope.tag { map["tag"] = value }
        if let value = envelope.sealedBoxBase64 { map["sealedBoxBase64"] = value }
        if let value = envelope.plaintextSHA256 { map["plaintextSHA256"] = value }
        if let value = envelope.plaintextHMAC { map["plaintextHMAC"] = value }
        if let value = envelope.integrityHashVersion { map["integrityHashVersion"] = Int(value) }
        if let value = envelope.aad { map["aad"] = value }
        return map
    }

    private static func equivalent(
        _ left: CloudVaultDocumentRewrapResult,
        _ right: CloudVaultDocumentRewrapResult
    ) -> Bool {
        left.changedFields == right.changedFields && valuesEqual(left.data, right.data)
    }

    private static func valuesEqual(_ left: Any, _ right: Any) -> Bool {
        if let left = left as? [String: Any], let right = right as? [String: Any] {
            guard left.keys == right.keys else { return false }
            return left.allSatisfy { key, value in
                guard let other = right[key] else { return false }
                return valuesEqual(value, other)
            }
        }
        if let left = left as? [Any], let right = right as? [Any] {
            return left.count == right.count && zip(left, right).allSatisfy(valuesEqual)
        }
        if let left = left as? NSObject, let right = right as? NSObject {
            return left.isEqual(right)
        }
        return false
    }

    private static func emit(
        category: String,
        backend: NativeBackend?,
        logger: any CloudVaultDocumentRewrapLogging
    ) {
        let version: String
        switch category {
        case "native_unavailable": version = "unavailable"
        case "abi_mismatch": version = "incompatible"
        case "invalid_input": version = "not_queried"
        default: version = backend?.coreVersion() ?? "unavailable"
        }
        logger.log(
            CloudVaultDocumentRewrapDiagnostic(
                operation: operation,
                category: category,
                coreVersion: version,
                count: DiagnosticCounter.shared.next(category: category)
            )
        )
    }

    private static func diagnosticCategory(for error: CloudVaultDocumentRewrapAdapterError) -> String {
        switch error {
        case .nativeUnavailable: "native_unavailable"
        case .abiMismatch: "abi_mismatch"
        case .invalidInput: "invalid_input"
        case .invalidResult: "invalid_result"
        case .nativeFailure: "native_error"
        }
    }

    private static func platformVaultKeyID(_ key: Data) -> String {
        "v1_" + String(PlatformCrypto.sha256Hex(key).prefix(32))
    }

    private static func exactInt64(_ value: Int?) throws -> Int64? {
        guard let value else { return nil }
        guard let exact = Int64(exactly: value) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidInput
        }
        return exact
    }

    private static func requiredString(_ raw: [String: Any], _ name: String) throws -> String {
        guard let value = raw[name] as? String else {
            throw CloudVaultDocumentRewrapAdapterError.invalidInput
        }
        return value
    }

    private static func optionalString(_ raw: [String: Any], _ name: String) throws -> String? {
        guard raw.keys.contains(name) else { return nil }
        return try requiredString(raw, name)
    }

    private static func requiredUInt32(_ raw: [String: Any], _ name: String) throws -> UInt32 {
        guard let value = try optionalUInt32(raw, name) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidInput
        }
        return value
    }

    private static func optionalUInt32(_ raw: [String: Any], _ name: String) throws -> UInt32? {
        guard let rawValue = raw[name] else { return nil }
        guard let number = rawValue as? NSNumber,
              !isBoolean(number) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidInput
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= 0,
              double <= Double(UInt32.max) else {
            throw CloudVaultDocumentRewrapAdapterError.invalidInput
        }
        return UInt32(double)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        // swift-corelibs-foundation has no standalone CoreFoundation module.
        return String(cString: number.objCType) == "c"
        #endif
    }

    #if canImport(OpenBurnBarDomainCoreFFI)
    private static func ffiEnvelope(_ envelope: Envelope) -> OpenBurnBarDomainCoreFFI.CloudVaultDocumentEnvelope {
        let kind: OpenBurnBarDomainCoreFFI.CloudVaultDocumentEnvelopeKind
        switch envelope.kind {
        case .sealedPayload: kind = .sealedPayload
        case .sealedText: kind = .sealedText
        case .blob: kind = .blob
        }
        return .init(
            kind: kind,
            fieldName: envelope.fieldName,
            schemaVersion: envelope.schemaVersion,
            algorithm: envelope.algorithm,
            keyVersion: envelope.keyVersion,
            vaultKeyId: envelope.vaultKeyID,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag,
            sealedBoxBase64: envelope.sealedBoxBase64,
            plaintextSha256: envelope.plaintextSHA256,
            plaintextHmac: envelope.plaintextHMAC,
            integrityHashVersion: envelope.integrityHashVersion,
            aad: envelope.aad,
            hasCreatedAt: envelope.hasCreatedAt
        )
    }

    private static func nativeEnvelope(
        _ envelope: OpenBurnBarDomainCoreFFI.CloudVaultDocumentEnvelope
    ) -> Envelope {
        let kind: Envelope.Kind
        switch envelope.kind {
        case .sealedPayload: kind = .sealedPayload
        case .sealedText: kind = .sealedText
        case .blob: kind = .blob
        }
        return Envelope(
            kind: kind,
            fieldName: envelope.fieldName,
            schemaVersion: envelope.schemaVersion,
            algorithm: envelope.algorithm,
            keyVersion: envelope.keyVersion,
            vaultKeyID: envelope.vaultKeyId,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag,
            sealedBoxBase64: envelope.sealedBoxBase64,
            plaintextSHA256: envelope.plaintextSha256,
            plaintextHMAC: envelope.plaintextHmac,
            integrityHashVersion: envelope.integrityHashVersion,
            aad: envelope.aad,
            hasCreatedAt: envelope.hasCreatedAt
        )
    }
    #endif
}

private final class DiagnosticCounter: @unchecked Sendable {
    static let shared = DiagnosticCounter()

    private let lock = NSLock()
    private var counts: [String: UInt64] = [:]

    func next(category: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let next = (counts[category] ?? 0) + 1
        counts[category] = next
        return next
    }
}
