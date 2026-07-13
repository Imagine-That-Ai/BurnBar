import Foundation

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum CloudVaultDomainCoreMigrationMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static func resolve(environment: [String: String]) -> Self {
        guard let raw = environment["OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE"]?.lowercased() else {
            return .legacy
        }
        return Self(rawValue: raw) ?? .legacy
    }
}

protocol CloudVaultDomainCoreLogging: Sendable {
    func log(_ message: String)
}

struct PlatformCloudVaultDomainCoreLogger: CloudVaultDomainCoreLogging {
    private let logger = PlatformLogger(
        subsystem: "com.openburnbar.core",
        category: "CloudVaultDomainCore"
    )

    func log(_ message: String) {
        logger.warning(message)
    }
}

enum CloudVaultDomainCoreAdapterError: Error, Equatable {
    case nativeUnavailable
    case invalidInput
}

enum CloudVaultDomainCoreAdapter {
    struct AESGCMDetachedBox: Equatable, Sendable {
        let nonce: Data
        let ciphertext: Data
        let tag: Data

        var combined: Data { nonce + ciphertext + tag }
    }

    struct RecoveryWrappedVaultKey: Equatable, Sendable {
        let combined: Data
        let verificationHash: String
    }

    struct EscrowWireParts: Equatable, Sendable {
        let ephemeralPublicKey: Data
        let aesGCMCombined: Data
    }

    static var isNativeAvailable: Bool {
        #if canImport(OpenBurnBarDomainCoreFFI)
        true
        #else
        false
        #endif
    }

    static func aadV1(
        uid: String,
        collection: String,
        docID: String,
        field: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(
            operation: "aad_v1",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultAadV1(
                uid: uid,
                collection: collection,
                docId: docID,
                field: field
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func aadV2(
        uid: String,
        collection: String,
        docID: String,
        field: String,
        schemaVersion: Int,
        purpose: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(
            operation: "aad_v2",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            guard let version = UInt32(exactly: schemaVersion) else {
                throw CloudVaultDomainCoreAdapterError.invalidInput
            }
            return try OpenBurnBarDomainCoreFFI.cloudVaultAadV2(
                uid: uid,
                collection: collection,
                docId: docID,
                field: field,
                schemaVersion: version,
                purpose: purpose
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func resolveAAD(
        envelopeAAD: String,
        context: CloudVaultAADContext,
        rejectLegacyV1: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(
            operation: "resolve_aad",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            guard let version = UInt32(exactly: context.schemaVersion) else {
                throw CloudVaultDomainCoreAdapterError.invalidInput
            }
            return try OpenBurnBarDomainCoreFFI.cloudVaultResolveAad(
                envelopeAad: envelopeAAD,
                context: .init(
                    uid: context.uid,
                    collection: context.collection,
                    docId: context.docID,
                    field: context.field,
                    schemaVersion: version,
                    purpose: context.purpose
                ),
                rejectLegacy: rejectLegacyV1
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func sha256Hex(
        _ data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(
            operation: "sha256",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            OpenBurnBarDomainCoreFFI.cloudVaultSha256Hex(data: data)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func vaultKeyID(
        for keyData: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(
            operation: "vault_key_id",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultKeyId(key: keyData)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func keyedHashHex(
        _ data: Data,
        keyData: Data,
        purpose: Purpose,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(
            operation: purpose.operation,
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultKeyedHashHex(
                data: data,
                key: keyData,
                purpose: purpose.ffiValue
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func expectedSessionBodyHash(
        _ data: Data,
        keyData: Data,
        bodyHashVersion: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(
            operation: "expected_session_body_hash",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            guard let version = UInt32(exactly: bodyHashVersion) else {
                throw CloudVaultDomainCoreAdapterError.invalidInput
            }
            return try OpenBurnBarDomainCoreFFI.cloudVaultExpectedSessionBodyHash(
                data: data,
                key: keyData,
                bodyHashVersion: version
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func sealAESGCMDetached(
        plaintext: Data,
        keyData: Data,
        nonce: Data,
        authenticating aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> AESGCMDetachedBox
    ) throws -> AESGCMDetachedBox {
        try select(
            operation: "aes_gcm_seal_detached",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            let box = try OpenBurnBarDomainCoreFFI.cloudVaultAesGcmSealDetached(
                plaintext: plaintext,
                key: keyData,
                nonce: nonce,
                aad: aad
            )
            return AESGCMDetachedBox(nonce: box.nonce, ciphertext: box.ciphertext, tag: box.tag)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func sealAESGCMCombined(
        plaintext: Data,
        keyData: Data,
        nonce: Data,
        authenticating aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(
            operation: "aes_gcm_seal_combined",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultAesGcmSealCombined(
                plaintext: plaintext,
                key: keyData,
                nonce: nonce,
                aad: aad
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func openAESGCMDetached(
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        keyData: Data,
        authenticating aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(
            operation: "aes_gcm_open_detached",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultAesGcmOpenDetached(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag,
                key: keyData,
                aad: aad
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func openAESGCMTextDetached(
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        keyData: Data,
        authenticating aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(
            operation: "aes_gcm_open_text_detached",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultAesGcmOpenTextDetached(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag,
                key: keyData,
                aad: aad
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func openAESGCMCombined(
        combined: Data,
        keyData: Data,
        authenticating aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(
            operation: "aes_gcm_open_combined",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultAesGcmOpenCombined(
                combined: combined,
                key: keyData,
                aad: aad
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func base64Encode(
        _ data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(
            operation: "base64_encode",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            OpenBurnBarDomainCoreFFI.cloudVaultBase64Encode(data: data)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func base64DecodeStrict(
        _ value: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(
            operation: "base64_decode_strict",
            environment: environment,
            logger: logger,
            legacy: legacy
        ) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultBase64DecodeStrict(value: value)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func normalizeRecoveryKey(
        _ recoveryKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(operation: "recovery_normalize", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultNormalizeRecoveryKey(recoveryKey: recoveryKey)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func recoveryWrappingKey(
        recoveryKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(operation: "recovery_wrapping_key", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultRecoveryWrappingKey(recoveryKey: recoveryKey)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func recoveryVerificationHash(
        recoveryKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> String
    ) throws -> String {
        try select(operation: "recovery_verification_hash", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultRecoveryVerificationHash(recoveryKey: recoveryKey)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func recoveryWrapVaultKey(
        vaultKey: Data,
        recoveryKey: String,
        nonce: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> RecoveryWrappedVaultKey
    ) throws -> RecoveryWrappedVaultKey {
        try select(operation: "recovery_wrap_vault_key", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            let wrapped = try OpenBurnBarDomainCoreFFI.cloudVaultRecoveryWrapVaultKey(
                vaultKey: vaultKey,
                recoveryKey: recoveryKey,
                nonce: nonce
            )
            return .init(combined: wrapped.combined, verificationHash: wrapped.verificationHash)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func recoveryOpenVaultKey(
        combined: Data,
        recoveryKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(operation: "recovery_open_vault_key", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultRecoveryOpenVaultKey(combined: combined, recoveryKey: recoveryKey)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func validateP256X963PublicKey(
        _ publicKey: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Bool
    ) throws {
        _ = try select(operation: "p256_validate_public_key", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultValidateP256X963PublicKey(publicKey: publicKey)
            return true
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func escrowWrappingKey(
        sharedSecret: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(operation: "escrow_wrapping_key", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultEscrowWrappingKey(sharedSecret: sharedSecret)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func escrowAssembleWire(
        ephemeralPublicKey: Data,
        aesGCMCombined: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(operation: "escrow_assemble_wire", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultEscrowAssembleWire(
                ephemeralPublicKey: ephemeralPublicKey,
                aesGcmCombined: aesGCMCombined
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func escrowSplitWire(
        _ wire: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> EscrowWireParts
    ) throws -> EscrowWireParts {
        try select(operation: "escrow_split_wire", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            let parts = try OpenBurnBarDomainCoreFFI.cloudVaultEscrowSplitWire(wire: wire)
            return .init(ephemeralPublicKey: parts.ephemeralPublicKey, aesGCMCombined: parts.aesGcmCombined)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func escrowSeal(
        plaintext: Data,
        ephemeralPublicKey: Data,
        sharedSecret: Data,
        nonce: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(operation: "escrow_seal", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultEscrowSeal(
                plaintext: plaintext,
                ephemeralPublicKey: ephemeralPublicKey,
                sharedSecret: sharedSecret,
                nonce: nonce
            )
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func escrowOpen(
        wire: Data,
        sharedSecret: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultDomainCoreLogging = PlatformCloudVaultDomainCoreLogger(),
        legacy: () throws -> Data
    ) throws -> Data {
        try select(operation: "escrow_open", environment: environment, logger: logger, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.cloudVaultEscrowOpen(wire: wire, sharedSecret: sharedSecret)
            #else
            throw CloudVaultDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    enum Purpose: Sendable {
        case blobIntegrity
        case sessionBody
        case sessionChunk
        case projectMemoryContent

        fileprivate var operation: String {
            switch self {
            case .blobIntegrity: "blob_integrity_hash"
            case .sessionBody: "session_body_hash"
            case .sessionChunk: "session_chunk_hash"
            case .projectMemoryContent: "project_memory_content_hash"
            }
        }

        #if canImport(OpenBurnBarDomainCoreFFI)
        fileprivate var ffiValue: OpenBurnBarDomainCoreFFI.CloudVaultHashPurpose {
            switch self {
            case .blobIntegrity: .blobIntegrity
            case .sessionBody: .sessionBody
            case .sessionChunk: .sessionChunk
            case .projectMemoryContent: .projectMemoryContent
            }
        }
        #endif
    }

    private static func select<T: Equatable>(
        operation: String,
        environment: [String: String],
        logger: any CloudVaultDomainCoreLogging,
        legacy: () throws -> T,
        rust: () throws -> T
    ) throws -> T {
        let mode = CloudVaultDomainCoreMigrationMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }

        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            logger.log("domain_core.cloudvault operation=\(operation) version=2 category=abi_mismatch")
            if requiresNative(environment) { throw CloudVaultDomainCoreAdapterError.nativeUnavailable }
            return try legacy()
        }

        let rustValue: T
        do {
            rustValue = try rust()
        } catch {
            logger.log("domain_core.cloudvault operation=\(operation) version=2 category=rust_error")
            if mode == .shadow { return try legacy() }
            throw map(error)
        }

        guard mode == .shadow else { return rustValue }
        let legacyValue = try legacy()
        if legacyValue != rustValue {
            logger.log(
                "domain_core.cloudvault operation=\(operation) version=2 category=value_mismatch legacy_count=1 rust_count=1"
            )
        }
        return legacyValue
        #else
        logger.log("domain_core.cloudvault operation=\(operation) version=2 category=native_unavailable")
        if requiresNative(environment) { throw CloudVaultDomainCoreAdapterError.nativeUnavailable }
        return try legacy()
        #endif
    }

    private static func requiresNative(_ environment: [String: String]) -> Bool {
        environment["OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"] == "1"
    }

    private static func map(_ error: Error) -> CloudVaultDomainCoreAdapterError {
        if let error = error as? CloudVaultDomainCoreAdapterError { return error }
        return .invalidInput
    }
}
