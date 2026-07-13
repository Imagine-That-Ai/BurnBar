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
        let old = mode == .shadow ? legacy() : nil
        let rust: Data
        do {
            rust = try OpenBurnBarDomainCoreFFI.hermesRelayAad(
                kind: kind.ffi,
                arguments: arguments
            )
        } catch {
            diagnostic("aad", "native_unavailable")
            if mode == .rust { throw error }
            return old ?? legacy()
        }
        guard mode == .shadow else { return rust }
        guard let old else { return legacy() }
        if old != rust { diagnostic("aad", "shadow_mismatch") }
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
            do {
                let opened = try OpenBurnBarDomainCoreFFI.hermesOpenBase64(
                    ciphertext: old,
                    key: key,
                    aad: aad
                )
                if opened != plaintext { diagnostic("seal", "shadow_mismatch") }
            } catch {
                diagnostic("seal", "native_error")
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
        #if canImport(OpenBurnBarDomainCoreFFI)
        return try selectBytes(operation: "open", environment: environment, legacy: legacy) {
            try OpenBurnBarDomainCoreFFI.hermesOpenBase64(
                ciphertext: ciphertext,
                key: key,
                aad: aad
            )
        }
        #else
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }
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
        let old = mode == .shadow ? legacy() : nil
        let rust: String
        do {
            rust = try OpenBurnBarDomainCoreFFI.hermesGatewayRelaySafetyCode(
                agentPublicKey: agent,
                phonePublicKey: phone
            )
        } catch {
            if mode == .rust { throw error }
            return old ?? legacy()
        }
        guard mode == .shadow else { return rust }
        guard let old else { return legacy() }
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
        #if canImport(OpenBurnBarDomainCoreFFI)
        return try selectBytes(operation: "hkdf", environment: environment, legacy: legacy) {
            try OpenBurnBarDomainCoreFFI.hermesHkdfSha256(
                inputKeyMaterial: inputKeyMaterial,
                salt: salt,
                info: info,
                outputByteCount: try checkedHkdfOutputByteCount(outputByteCount)
            )
        }
        #else
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return try legacy() }
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
        return try selectBytesWhenNativeAvailable(
            operation: operation,
            mode: mode,
            legacy: legacy,
            rust: rust
        )
        #else
        if mode == .shadow { return try legacy() }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
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
        rust: () throws -> Data
    ) throws -> Data {
        guard mode != .legacy else { return try legacy() }
        guard mode == .shadow else { return try rust() }

        let old = try legacy()
        let value: Data
        do {
            value = try rust()
        } catch {
            diagnostic(operation, "native_error")
            return old
        }
        if old != value { diagnostic(operation, "shadow_mismatch") }
        return old
    }

    private static func diagnostic(_ operation: String, _ outcome: String) {
        NSLog("domain_core.hermes.%@ %@", operation, outcome)
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
