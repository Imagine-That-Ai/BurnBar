import Foundation

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

enum HermesDomainCoreMode: String, Sendable {
    case legacy
    case shadow
    case rust

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        guard let raw = environment["OPENBURNBAR_DOMAIN_CORE_HERMES_MODE"]?.lowercased() else {
            return .legacy
        }
        return Self(rawValue: raw) ?? .legacy
    }
}

enum HermesDomainCoreAdapterError: Error {
    case nativeUnavailable
}

enum HermesDomainCoreAdapter {
    static var isNativeAvailable: Bool {
        #if canImport(OpenBurnBarDomainCoreFFI)
        OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2
        #else
        false
        #endif
    }

    static func aad(
        kind: HermesAadKindAdapter,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () -> Data
    ) -> Data {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return legacy() }
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            diagnostic("aad", "native_unavailable")
            if mode == .rust { preconditionFailure("Hermes Rust mode requires ABI v2") }
            return legacy()
        }
        let rust: Data
        do {
            rust = try OpenBurnBarDomainCoreFFI.hermesRelayAad(
                kind: kind.ffi,
                arguments: arguments
            )
        } catch {
            diagnostic("aad", "native_unavailable")
            if mode == .rust { preconditionFailure("Hermes Rust AAD validation failed: \(error)") }
            return legacy()
        }
        guard mode == .shadow else { return rust }
        let old = legacy()
        if old != rust { diagnostic("aad", "shadow_mismatch") }
        return old
        #else
        diagnostic("aad", "native_unavailable")
        if mode == .rust { preconditionFailure("Hermes Rust mode requires the native core") }
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
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
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
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
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
    ) -> String {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        guard mode != .legacy else { return legacy() }
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            if mode == .rust { preconditionFailure("Hermes Rust mode requires ABI v2") }
            return legacy()
        }
        let rust: String
        do {
            rust = try OpenBurnBarDomainCoreFFI.hermesGatewayRelaySafetyCode(
                agentPublicKey: agent,
                phonePublicKey: phone
            )
        } catch {
            if mode == .rust { preconditionFailure("Hermes Rust safety-code validation failed: \(error)") }
            return legacy()
        }
        guard mode == .shadow else { return rust }
        let old = legacy()
        if old != rust { diagnostic("safety_code", "shadow_mismatch") }
        return old
        #else
        if mode == .rust { preconditionFailure("Hermes Rust mode requires the native core") }
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
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            diagnostic("hkdf", "abi_mismatch")
            if mode == .shadow { return try legacy() }
            throw HermesDomainCoreAdapterError.nativeUnavailable
        }
        let rust = try OpenBurnBarDomainCoreFFI.hermesHkdfSha256(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: info,
            outputByteCount: UInt32(outputByteCount)
        )
        guard mode == .shadow else { return rust }
        let old = try legacy()
        if old != rust { diagnostic("hkdf", "shadow_mismatch") }
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
        guard OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2 else {
            diagnostic(operation, "abi_mismatch")
            if mode == .shadow { return try legacy() }
            throw HermesDomainCoreAdapterError.nativeUnavailable
        }
        let value = try rust()
        guard mode == .shadow else { return value }
        let old = try legacy()
        if old != value { diagnostic(operation, "shadow_mismatch") }
        return old
        #else
        if mode == .shadow { return try legacy() }
        throw HermesDomainCoreAdapterError.nativeUnavailable
        #endif
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
