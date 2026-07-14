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
}

enum HermesDomainCoreAdapter {
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
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return legacy() }
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            diagnostic("aad", "native_unavailable")
            if mode == .rust { throw HermesDomainCoreAdapterError.nativeUnavailable }
            return legacy()
        }
        let rust: Data
        let rustStarted = Date.timeIntervalSinceReferenceDate
        do {
            rust = try OpenBurnBarDomainCoreFFI.hermesRelayAad(
                kind: kind.ffi,
                arguments: arguments
            )
        } catch {
            diagnostic("aad", "native_unavailable")
            if mode == .rust { throw error }
            return legacy()
        }
        guard mode == .shadow else { return rust }
        let rustMicros = elapsedMicros(since: rustStarted)
        let legacyStarted = Date.timeIntervalSinceReferenceDate
        let old = legacy()
        let matches = old == rust
        if !matches { diagnostic("aad", "shadow_mismatch") }
        record("aad", "aad", matches, matches ? nil : "result_mismatch", elapsedMicros(since: legacyStarted), rustMicros)
        return old
        #else
        diagnostic("aad", "native_unavailable")
        if mode == .rust { throw HermesDomainCoreAdapterError.nativeUnavailable }
        return legacy()
        #endif
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
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            diagnostic("seal", "abi_mismatch")
            if mode == .shadow { return try legacy() }
            throw HermesDomainCoreAdapterError.nativeUnavailable
        }
        if mode == .shadow {
            let old = try legacy()
            let opened = try? OpenBurnBarDomainCoreFFI.hermesOpenBase64(
                ciphertext: old,
                key: key,
                aad: aad
            )
            if opened != plaintext { diagnostic("seal", "shadow_mismatch") }
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
        if mode == .shadow { return try legacy() }
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
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            diagnostic("open", "abi_mismatch")
            if mode == .shadow { return try legacy() }
            throw HermesDomainCoreAdapterError.nativeUnavailable
        }
        let rust = try OpenBurnBarDomainCoreFFI.hermesOpenBase64(
            ciphertext: ciphertext,
            key: key,
            aad: aad
        )
        guard mode == .shadow else { return rust }
        let old = try legacy()
        if old != rust { diagnostic("open", "shadow_mismatch") }
        return old
        #else
        diagnostic("open", "native_unavailable")
        if mode == .shadow { return try legacy() }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
    }

    static func safetyCode(
        agent: Data,
        phone: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () -> String
    ) throws -> String {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return legacy() }
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            if mode == .rust { throw HermesDomainCoreAdapterError.nativeUnavailable }
            return legacy()
        }
        let rust: String
        do {
            rust = try OpenBurnBarDomainCoreFFI.hermesGatewayRelaySafetyCode(
                agentPublicKey: agent,
                phonePublicKey: phone
            )
        } catch {
            if mode == .rust { throw error }
            return legacy()
        }
        guard mode == .shadow else { return rust }
        let old = legacy()
        if old != rust { diagnostic("safety_code", "shadow_mismatch") }
        return old
        #else
        if mode == .rust { throw HermesDomainCoreAdapterError.nativeUnavailable }
        return legacy()
        #endif
    }

    static func keyWrapInfoV1(
        aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        #if canImport(OpenBurnBarDomainCoreFFI)
        try selectBytes(operation: "key_wrap_info_v1", environment: environment, legacy: legacy) {
            try OpenBurnBarDomainCoreFFI.hermesKeyWrapInfoV1(aad: aad)
        }
        #else
        if HermesDomainCoreMode.resolve(environment: environment) != .rust { return try legacy() }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
    }

    static func keyWrapInfoV2(
        aad: Data,
        enc: Data,
        recipient: Data,
        sender: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        #if canImport(OpenBurnBarDomainCoreFFI)
        try selectBytes(operation: "key_wrap_info_v2", environment: environment, legacy: legacy) {
            try OpenBurnBarDomainCoreFFI.hermesKeyWrapInfoV2(
                aad: aad,
                enc: enc,
                recipientPublicKey: recipient,
                senderPublicKey: sender
            )
        }
        #else
        if HermesDomainCoreMode.resolve(environment: environment) != .rust { return try legacy() }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
    }

    static func hpkeV3Info(
        aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        #if canImport(OpenBurnBarDomainCoreFFI)
        try selectBytes(operation: "hpke_v3_info", environment: environment, legacy: legacy) {
            try OpenBurnBarDomainCoreFFI.hermesHpkeV3Info(aad: aad)
        }
        #else
        if HermesDomainCoreMode.resolve(environment: environment) != .rust { return try legacy() }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
    }

    static func hkdf(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            diagnostic("hkdf", "abi_mismatch")
            if mode == .shadow { return try legacy() }
            throw HermesDomainCoreAdapterError.nativeUnavailable
        }
        let rustStarted = Date.timeIntervalSinceReferenceDate
        let rust = try OpenBurnBarDomainCoreFFI.hermesHkdfSha256(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: info,
            outputByteCount: UInt32(outputByteCount)
        )
        guard mode == .shadow else { return rust }
        let rustMicros = elapsedMicros(since: rustStarted)
        let legacyStarted = Date.timeIntervalSinceReferenceDate
        let old = try legacy()
        let matches = old == rust
        if !matches { diagnostic("hkdf", "shadow_mismatch") }
        record("hkdf", "payload-keywrap", matches, matches ? nil : "result_mismatch", elapsedMicros(since: legacyStarted), rustMicros)
        return old
        #else
        if mode == .shadow { return try legacy() }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
    }

    private static func selectBytes(
        operation: String,
        environment: [String: String],
        legacy: () throws -> Data,
        rust: () throws -> Data
    ) throws -> Data {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 3 else {
            diagnostic(operation, "abi_mismatch")
            if mode == .shadow { return try legacy() }
            throw HermesDomainCoreAdapterError.nativeUnavailable
        }
        let rustStarted = Date.timeIntervalSinceReferenceDate
        let value = try rust()
        guard mode == .shadow else { return value }
        let rustMicros = elapsedMicros(since: rustStarted)
        let legacyStarted = Date.timeIntervalSinceReferenceDate
        let old = try legacy()
        let matches = old == value
        if !matches { diagnostic(operation, "shadow_mismatch") }
        record(
            operation,
            operation.contains("hpke") ? "hpke-info" : "payload-keywrap",
            matches,
            matches ? nil : "result_mismatch",
            elapsedMicros(since: legacyStarted),
            rustMicros
        )
        return old
        #else
        if mode == .shadow { return try legacy() }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
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
        _ legacyMicros: UInt64,
        _ rustMicros: UInt64
    ) {
        #if canImport(OpenBurnBarDomainCoreFFI)
        DomainCoreShadowComparisonCollector.record(.init(
            domain: "hermes",
            slice: slice,
            operation: operation,
            coreVersion: OpenBurnBarDomainCoreFFI.domainCoreVersion(),
            outcome: matches ? "match" : "mismatch",
            mismatchCategory: category,
            legacyMicros: legacyMicros,
            rustMicros: rustMicros
        ))
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
