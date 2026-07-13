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
