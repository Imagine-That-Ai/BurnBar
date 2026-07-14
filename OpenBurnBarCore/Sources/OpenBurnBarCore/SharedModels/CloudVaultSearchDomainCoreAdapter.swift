import Foundation
import OpenBurnBarKernel

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum CloudVaultSearchDomainCoreMigrationMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static let environmentKey = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE"

    static func resolve(environment: [String: String]) -> Self {
        Self(rawValue: DomainCoreBuildProfileResolver.mode(for: .cloudVaultSearch, environment: environment).rawValue) ?? .legacy
    }
}

protocol CloudVaultSearchDomainCoreLogging {
    func log(_ message: String)
}

struct PlatformCloudVaultSearchDomainCoreLogger: CloudVaultSearchDomainCoreLogging {
    private let logger = PlatformLogger(
        subsystem: "com.openburnbar.core",
        category: "CloudVaultSearchDomainCore"
    )

    func log(_ message: String) {
        logger.warning(message)
    }
}

enum CloudVaultSearchDomainCoreAdapterError: Error, Equatable {
    case nativeUnavailable
    case abiMismatch
    case invalidInput
    case invalidResult
    case nativeFailure
}

enum CloudVaultSearchDomainCoreOperation: String, CaseIterable, Sendable {
    case token
    case index
    case query
    case semantic
}

enum CloudVaultSearchDomainCoreAdapter {
    static let requiredABIVersion: UInt32 = 3

    struct NativeBackend {
        let abiVersion: () -> UInt32
        let coreVersion: () -> String
        let search: (
            _ operation: CloudVaultSearchDomainCoreOperation,
            _ text: String,
            _ keyData: Data,
            _ limit: Int32
        ) throws -> [String]
    }

    static var isNativeAvailable: Bool {
        productionBackend != nil
    }

    static var productionBackend: NativeBackend? {
        #if canImport(OpenBurnBarDomainCoreFFI)
        NativeBackend(
            abiVersion: { DomainCoreNativeProbe.abiVersion() ?? 0 },
            coreVersion: { OpenBurnBarDomainCoreFFI.domainCoreVersion() },
            search: { operation, text, keyData, limit in
                let ffiOperation: OpenBurnBarDomainCoreFFI.CloudVaultSearchOperation = switch operation {
                case .token: .token
                case .index: .index
                case .query: .query
                case .semantic: .semantic
                }
                let result = try OpenBurnBarDomainCoreFFI.cloudVaultSearch(
                    request: .init(
                        operation: ffiOperation,
                        text: text,
                        vaultKey: keyData,
                        limit: limit
                    )
                )
                guard result.operation == ffiOperation else {
                    throw CloudVaultSearchDomainCoreAdapterError.invalidResult
                }
                return result.hashes
            }
        )
        #else
        nil
        #endif
    }

    static func hashes(
        operation: CloudVaultSearchDomainCoreOperation,
        text: String,
        keyData: Data,
        limit: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: any CloudVaultSearchDomainCoreLogging = PlatformCloudVaultSearchDomainCoreLogger(),
        backend: NativeBackend? = productionBackend,
        legacy: () throws -> [String]
    ) throws -> [String] {
        let mode = CloudVaultSearchDomainCoreMigrationMode.resolve(environment: environment)
        return try hashes(
            operation: operation,
            text: text,
            keyData: keyData,
            limit: limit,
            mode: mode,
            logger: logger,
            backend: backend,
            legacy: legacy
        )
    }

    static func hashes(
        operation: CloudVaultSearchDomainCoreOperation,
        text: String,
        keyData: Data,
        limit: Int,
        mode: CloudVaultSearchDomainCoreMigrationMode,
        logger: any CloudVaultSearchDomainCoreLogging,
        backend: NativeBackend?,
        legacy: () throws -> [String]
    ) throws -> [String] {
        guard mode != .legacy else { return try legacy() }

        let legacyHashes: [String]?
        let legacyMicros: UInt64
        if mode == .shadow {
            let started = Date.timeIntervalSinceReferenceDate
            legacyHashes = try legacy()
            legacyMicros = elapsedMicros(since: started)
        } else {
            legacyHashes = nil
            legacyMicros = 0
        }

        guard let backend else {
            emit(operation: operation, category: "native_unavailable", core: "unavailable", logger: logger)
            guard mode == .shadow else { throw CloudVaultSearchDomainCoreAdapterError.nativeUnavailable }
            record(operation, false, "native_unavailable", "0.0.0-native-unavailable", legacyMicros, 0)
            return try requiredShadowValue(legacyHashes)
        }

        guard backend.abiVersion() == requiredABIVersion else {
            emit(operation: operation, category: "abi_mismatch", core: "incompatible", logger: logger)
            guard mode == .shadow else { throw CloudVaultSearchDomainCoreAdapterError.abiMismatch }
            record(operation, false, "native_unavailable", "0.0.0-abi-mismatch", legacyMicros, 0)
            return try requiredShadowValue(legacyHashes)
        }
        let coreVersion = backend.coreVersion()

        guard let ffiLimit = Int32(exactly: limit) else {
            emit(operation: operation, category: "invalid_input", core: coreVersion, logger: logger)
            guard mode == .shadow else { throw CloudVaultSearchDomainCoreAdapterError.invalidInput }
            record(operation, false, "invalid_result", coreVersion, legacyMicros, 0)
            return try requiredShadowValue(legacyHashes)
        }

        let rustHashes: [String]
        let rustStarted = Date.timeIntervalSinceReferenceDate
        do {
            rustHashes = try backend.search(operation, text, keyData, ffiLimit)
        } catch {
            emit(operation: operation, category: "native_error", core: coreVersion, logger: logger)
            guard mode == .shadow else {
                if let adapterError = error as? CloudVaultSearchDomainCoreAdapterError {
                    throw adapterError
                }
                throw CloudVaultSearchDomainCoreAdapterError.nativeFailure
            }
            record(operation, false, "native_error", coreVersion, legacyMicros, elapsedMicros(since: rustStarted))
            return try requiredShadowValue(legacyHashes)
        }

        guard mode == .shadow else { return rustHashes }
        guard let legacyHashes else { throw CloudVaultSearchDomainCoreAdapterError.invalidResult }
        let matches = legacyHashes == rustHashes
        if !matches {
            emit(operation: operation, category: "value_mismatch", core: coreVersion, logger: logger)
        }
        record(
            operation,
            matches,
            matches ? nil : "result_mismatch",
            coreVersion,
            legacyMicros,
            elapsedMicros(since: rustStarted)
        )
        return legacyHashes
    }

    private static func elapsedMicros(since started: TimeInterval) -> UInt64 {
        UInt64(min(600_000_000, max(0, ((Date.timeIntervalSinceReferenceDate - started) * 1_000_000).rounded())))
    }

    private static func record(
        _ operation: CloudVaultSearchDomainCoreOperation,
        _ matches: Bool,
        _ category: String?,
        _ coreVersion: String,
        _ legacyMicros: UInt64,
        _ rustMicros: UInt64
    ) {
        DomainCoreShadowComparisonCollector.record(.init(
            domain: "cloudvault",
            slice: "search",
            operation: operation.rawValue,
            coreVersion: coreVersion,
            outcome: matches ? "match" : "mismatch",
            mismatchCategory: category,
            legacyMicros: legacyMicros,
            rustMicros: rustMicros
        ))
    }

    private static func requiredShadowValue(_ value: [String]?) throws -> [String] {
        guard let value else { throw CloudVaultSearchDomainCoreAdapterError.invalidResult }
        return value
    }

    private static func emit(
        operation: CloudVaultSearchDomainCoreOperation,
        category: String,
        core: String,
        logger: any CloudVaultSearchDomainCoreLogging
    ) {
        logger.log(
            "domain_core.cloudvault_search operation=\(operation.rawValue) category=\(category) core=\(core)"
        )
    }
}
