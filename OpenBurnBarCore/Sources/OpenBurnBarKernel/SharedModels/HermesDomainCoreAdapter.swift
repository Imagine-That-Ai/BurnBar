import Foundation

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum HermesDomainCoreMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        Self(rawValue: DomainCoreBuildProfileResolver.mode(for: .hermes, environment: environment).rawValue) ?? .legacy
    }
}

enum HermesDomainCoreAdapterError: Error {
    case nativeUnavailable
    case invalidInput
}

enum HermesDomainCoreAdapter {
    enum NativeStatus: Equatable {
        case available
        case unavailable(coreVersion: String, mismatchCategory: String)
    }

    static var isNativeAvailable: Bool {
        #if canImport(OpenBurnBarDomainCoreFFI)
        OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3
        #else
        false
        #endif
    }

    static func aad(
        kind: HermesAadKindAdapter,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () -> Data
    ) throws -> Data {
        try selectBytes(operation: "aad", environment: environment, legacy: { legacy() }, rust: {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.hermesRelayAad(
                kind: kind.ffi,
                arguments: arguments
            )
            #else
            throw HermesDomainCoreAdapterError.nativeUnavailable
            #endif
        })
    }

    static func seal(
        plaintext: Data,
        key: Data,
        aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> String
    ) throws -> String {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }
        let legacyStarted = Date.timeIntervalSinceReferenceDate
        let old: String?
        if mode == .shadow {
            old = try legacy()
        } else {
            old = nil
        }
        let legacyMicros = mode == .shadow ? elapsedMicros(since: legacyStarted) : 0
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            diagnostic("seal", "abi_mismatch")
            if let old {
                record(
                    "seal", "payload-keywrap", false, "native_error",
                    "0.0.0-abi-mismatch", legacyMicros, 0
                )
                return old
            }
            throw HermesDomainCoreAdapterError.nativeUnavailable
        }
        if let old {
            let coreVersion = OpenBurnBarDomainCoreFFI.domainCoreVersion()
            let rustStarted = Date.timeIntervalSinceReferenceDate
            do {
                let opened = try OpenBurnBarDomainCoreFFI.hermesOpenBase64(
                    ciphertext: old,
                    key: key,
                    aad: aad
                )
                let matches = opened == plaintext
                if !matches { diagnostic("seal", "shadow_mismatch") }
                record(
                    "seal", "payload-keywrap", matches, matches ? nil : "result_mismatch",
                    coreVersion, legacyMicros, elapsedMicros(since: rustStarted)
                )
            } catch {
                diagnostic("seal", "native_error")
                record(
                    "seal", "payload-keywrap", false, "native_error",
                    coreVersion, legacyMicros, elapsedMicros(since: rustStarted)
                )
            }
            return old
        }
        let nonce = try PlatformCrypto.secureRandomBytes(count: 12)
        return try OpenBurnBarDomainCoreFFI.hermesSealBase64(
            plaintext: plaintext,
            key: key,
            aad: aad,
            nonce: nonce
        )
        #else
        diagnostic("seal", "native_unavailable")
        if let old {
            record(
                "seal", "payload-keywrap", false, "native_unavailable",
                "0.0.0-native-unavailable", legacyMicros, 0
            )
            return old
        }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
    }

    static func open(
        ciphertext: String,
        key: Data,
        aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        try selectBytes(operation: "open", environment: environment, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.hermesOpenBase64(
                ciphertext: ciphertext,
                key: key,
                aad: aad
            )
            #else
            throw HermesDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func safetyCode(
        agent: Data,
        phone: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () -> String
    ) throws -> String {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        return try selectValue(
            operation: "safety_code",
            mode: mode,
            nativeStatus: nativeStatus,
            coreVersion: currentCoreVersion,
            legacy: legacy,
            rust: {
                #if canImport(OpenBurnBarDomainCoreFFI)
                try OpenBurnBarDomainCoreFFI.hermesGatewayRelaySafetyCode(
                    agentPublicKey: agent,
                    phonePublicKey: phone
                )
                #else
                throw HermesDomainCoreAdapterError.nativeUnavailable
                #endif
            },
            equivalent: ==,
            recordComparison: DomainCoreShadowComparisonCollector.record
        )
    }

    static func keyWrapInfoV1(
        aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        try selectBytes(operation: "key_wrap_info_v1", environment: environment, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.hermesKeyWrapInfoV1(aad: aad)
            #else
            throw HermesDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func keyWrapInfoV2(
        aad: Data,
        enc: Data,
        recipient: Data,
        sender: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        try selectBytes(operation: "key_wrap_info_v2", environment: environment, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.hermesKeyWrapInfoV2(
                aad: aad,
                enc: enc,
                recipientPublicKey: recipient,
                senderPublicKey: sender
            )
            #else
            throw HermesDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func hpkeV3Info(
        aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        try selectBytes(operation: "hpke_v3_info", environment: environment, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.hermesHpkeV3Info(aad: aad)
            #else
            throw HermesDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    static func hkdf(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        return try selectBytes(operation: "hkdf", environment: environment, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.hermesHkdfSha256(
                inputKeyMaterial: inputKeyMaterial,
                salt: salt,
                info: info,
                outputByteCount: try checkedHkdfOutputByteCount(outputByteCount)
            )
            #else
            throw HermesDomainCoreAdapterError.nativeUnavailable
            #endif
        }
    }

    private static func selectBytes(
        operation: String,
        environment: [String: String],
        legacy: () throws -> Data,
        rust: () throws -> Data
    ) throws -> Data {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        return try selectBytes(
            operation: operation,
            mode: mode,
            nativeStatus: nativeStatus,
            coreVersion: currentCoreVersion,
            legacy: legacy,
            rust: rust,
            recordComparison: DomainCoreShadowComparisonCollector.record
        )
    }

    static func checkedHkdfOutputByteCount(_ value: Int) throws -> UInt32 {
        guard (1 ... 255 * 32).contains(value), let value = UInt32(exactly: value) else {
            throw HermesDomainCoreAdapterError.invalidInput
        }
        return value
    }

    static func selectBytesWhenNativeAvailable(
        operation: String,
        mode: HermesDomainCoreMode,
        legacy: () throws -> Data,
        rust: () throws -> Data,
        coreVersion: () -> String = { "0.0.0-native-unavailable" },
        recordComparison: (DomainCoreShadowComparison) -> Void = DomainCoreShadowComparisonCollector.record
    ) throws -> Data {
        try selectBytes(
            operation: operation,
            mode: mode,
            nativeStatus: { .available },
            coreVersion: coreVersion,
            legacy: legacy,
            rust: rust,
            recordComparison: recordComparison
        )
    }

    static func selectBytes(
        operation: String,
        mode: HermesDomainCoreMode,
        nativeStatus: () -> NativeStatus,
        coreVersion: () -> String,
        legacy: () throws -> Data,
        rust: () throws -> Data,
        recordComparison: (DomainCoreShadowComparison) -> Void
    ) throws -> Data {
        try selectValue(
            operation: operation,
            mode: mode,
            nativeStatus: nativeStatus,
            coreVersion: coreVersion,
            legacy: legacy,
            rust: rust,
            equivalent: ==,
            recordComparison: recordComparison
        )
    }

    static func selectValue<T: Equatable>(
        operation: String,
        mode: HermesDomainCoreMode,
        nativeStatus: () -> NativeStatus,
        coreVersion: () -> String,
        legacy: () throws -> T,
        rust: () throws -> T,
        equivalent: (T, T) -> Bool,
        recordComparison: (DomainCoreShadowComparison) -> Void
    ) throws -> T {
        guard mode != .legacy else { return try legacy() }
        guard mode == .shadow else {
            guard nativeStatus() == .available else {
                throw HermesDomainCoreAdapterError.nativeUnavailable
            }
            return try rust()
        }

        let legacyStarted = Date.timeIntervalSinceReferenceDate
        let old = try legacy()
        let legacyMicros = elapsedMicros(since: legacyStarted)
        switch nativeStatus() {
        case .available:
            break
        case let .unavailable(unavailableCoreVersion, mismatchCategory):
            diagnostic(operation, mismatchCategory == "native_error" ? "abi_mismatch" : "native_unavailable")
            record(
                operation,
                slice(for: operation),
                false,
                mismatchCategory,
                unavailableCoreVersion,
                legacyMicros,
                0,
                recordComparison: recordComparison
            )
            return old
        }

        let comparisonCoreVersion = coreVersion()
        let value: T
        let rustStarted = Date.timeIntervalSinceReferenceDate
        do {
            value = try rust()
        } catch {
            diagnostic(operation, "native_error")
            record(
                operation,
                slice(for: operation),
                false,
                "native_error",
                comparisonCoreVersion,
                legacyMicros,
                elapsedMicros(since: rustStarted),
                recordComparison: recordComparison
            )
            return old
        }
        let matches = equivalent(old, value)
        if !matches { diagnostic(operation, "shadow_mismatch") }
        record(
            operation,
            slice(for: operation),
            matches,
            matches ? nil : "result_mismatch",
            comparisonCoreVersion,
            legacyMicros,
            elapsedMicros(since: rustStarted),
            recordComparison: recordComparison
        )
        return old
    }

    private static func diagnostic(_ operation: String, _ outcome: String) {
        NSLog("domain_core.hermes.%@ %@", operation, outcome)
    }

    private static func elapsedMicros(since started: TimeInterval) -> UInt64 {
        UInt64(min(600_000_000, max(0, ((Date.timeIntervalSinceReferenceDate - started) * 1_000_000).rounded())))
    }

    private static func record(
        _ operation: String,
        _ slice: String,
        _ matches: Bool,
        _ category: String?,
        _ coreVersion: String,
        _ legacyMicros: UInt64,
        _ rustMicros: UInt64,
        recordComparison: (DomainCoreShadowComparison) -> Void = DomainCoreShadowComparisonCollector.record
    ) {
        recordComparison(.init(
            domain: "hermes",
            slice: slice,
            operation: operation,
            coreVersion: coreVersion,
            outcome: matches ? "match" : "mismatch",
            mismatchCategory: category,
            legacyMicros: legacyMicros,
            rustMicros: rustMicros
        ))
    }

    private static func slice(for operation: String) -> String {
        operation == "aad" ? "aad" : operation.contains("hpke") ? "hpke-info" : "payload-keywrap"
    }

    private static func nativeStatus() -> NativeStatus {
        #if canImport(OpenBurnBarDomainCoreFFI)
        if OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 {
            return .available
        }
        return .unavailable(
            coreVersion: "0.0.0-abi-mismatch",
            mismatchCategory: "native_error"
        )
        #else
        return .unavailable(
            coreVersion: "0.0.0-native-unavailable",
            mismatchCategory: "native_unavailable"
        )
        #endif
    }

    private static func currentCoreVersion() -> String {
        #if canImport(OpenBurnBarDomainCoreFFI)
        OpenBurnBarDomainCoreFFI.domainCoreVersion()
        #else
        "0.0.0-native-unavailable"
        #endif
    }
}

enum HermesAadKindAdapter {
    case request, key, authenticatedRequest, authenticatedKey, chunk
    case mediaSealKey, controlSealKey, gatewayEvent, gatewayEventKey
    case gatewayMessage, gatewayMessageKey, gatewayAttachmentKey
    case gatewayAttachmentManifest, gatewayAttachmentBody

    #if canImport(OpenBurnBarDomainCoreFFI)
    var ffi: OpenBurnBarDomainCoreFFI.HermesAadKind {
        switch self {
        case .request: .request
        case .key: .key
        case .authenticatedRequest: .authenticatedRequest
        case .authenticatedKey: .authenticatedKey
        case .chunk: .chunk
        case .mediaSealKey: .mediaSealKey
        case .controlSealKey: .controlSealKey
        case .gatewayEvent: .gatewayEvent
        case .gatewayEventKey: .gatewayEventKey
        case .gatewayMessage: .gatewayMessage
        case .gatewayMessageKey: .gatewayMessageKey
        case .gatewayAttachmentKey: .gatewayAttachmentKey
        case .gatewayAttachmentManifest: .gatewayAttachmentManifest
        case .gatewayAttachmentBody: .gatewayAttachmentBody
        }
    }
    #endif
}
