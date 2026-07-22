import Foundation
import OpenBurnBarDomainCoreRuntime

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
        return try DomainCoreShadowRuntime.selectVerifiedLegacy(
            domain: "hermes",
            slice: "payload-keywrap",
            operation: "seal",
            mode: DomainCoreBuildMode(rawValue: mode.rawValue) ?? .legacy,
            nativeStatus: nativeStatus,
            coreVersion: currentCoreVersion,
            legacy: legacy,
            rustAuthority: {
                #if canImport(OpenBurnBarDomainCoreFFI)
                try OpenBurnBarDomainCoreFFI.hermesSealBase64(
                    plaintext: plaintext,
                    key: key,
                    aad: aad,
                    nonce: PlatformCrypto.secureRandomBytes(count: 12)
                )
                #else
                throw HermesDomainCoreAdapterError.nativeUnavailable
                #endif
            },
            verifyLegacyWithRust: { ciphertext in
                #if canImport(OpenBurnBarDomainCoreFFI)
                try OpenBurnBarDomainCoreFFI.hermesOpenBase64(
                    ciphertext: ciphertext,
                    key: key,
                    aad: aad
                ) == plaintext
                #else
                throw HermesDomainCoreAdapterError.nativeUnavailable
                #endif
            },
            nativeUnavailableError: HermesDomainCoreAdapterError.nativeUnavailable,
            diagnostic: diagnostic
        )
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

    /// Combined AES-GCM seal for the relay key-wrap AEAD (raw bytes, no base64
    /// detour). Mirrors ``seal(plaintext:key:aad:environment:legacy:)`` but
    /// returns the combined ciphertext+tag `Data` the wrap path concatenates
    /// with the ephemeral public key. Shadow verifies the legacy output
    /// round-trips through Rust; in rust mode the Rust-produced combined bytes
    /// are returned and failures propagate without fallback.
    static func sealCombined(
        plaintext: Data,
        key: Data,
        aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        let mode = HermesDomainCoreMode.resolve(environment: environment)
        return try DomainCoreShadowRuntime.selectVerifiedLegacy(
            domain: "hermes",
            slice: "payload-keywrap",
            operation: "seal_combined",
            mode: DomainCoreBuildMode(rawValue: mode.rawValue) ?? .legacy,
            nativeStatus: nativeStatus,
            coreVersion: currentCoreVersion,
            legacy: legacy,
            rustAuthority: {
                #if canImport(OpenBurnBarDomainCoreFFI)
                try OpenBurnBarDomainCoreFFI.hermesSealCombined(
                    plaintext: plaintext,
                    key: key,
                    aad: aad,
                    nonce: PlatformCrypto.secureRandomBytes(count: 12)
                )
                #else
                throw HermesDomainCoreAdapterError.nativeUnavailable
                #endif
            },
            verifyLegacyWithRust: { combined in
                #if canImport(OpenBurnBarDomainCoreFFI)
                try OpenBurnBarDomainCoreFFI.hermesOpenCombined(
                    combined: combined,
                    key: key,
                    aad: aad
                ) == plaintext
                #else
                throw HermesDomainCoreAdapterError.nativeUnavailable
                #endif
            },
            nativeUnavailableError: HermesDomainCoreAdapterError.nativeUnavailable,
            diagnostic: diagnostic
        )
    }

    /// Combined AES-GCM open for the relay key-wrap AEAD (raw bytes). Mirrors
    /// ``open(ciphertext:key:aad:environment:legacy:)`` but operates on the
    /// combined ciphertext+tag `Data` the unwrap path splits off the envelope.
    /// Shadow compares Rust and legacy and returns legacy; in rust mode the
    /// Rust-produced plaintext is returned and failures propagate without
    /// fallback.
    static func openCombined(
        combined: Data,
        key: Data,
        aad: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacy: () throws -> Data
    ) throws -> Data {
        try selectBytes(operation: "open_combined", environment: environment, legacy: legacy) {
            #if canImport(OpenBurnBarDomainCoreFFI)
            try OpenBurnBarDomainCoreFFI.hermesOpenCombined(
                combined: combined,
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
        return try DomainCoreShadowRuntime.select(
            domain: "hermes",
            slice: "payload-keywrap",
            operation: "safety_code",
            mode: DomainCoreBuildMode(rawValue: mode.rawValue) ?? .legacy,
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
            nativeUnavailableError: HermesDomainCoreAdapterError.nativeUnavailable,
            diagnostic: diagnostic,
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

    static func selectBytes(
        operation: String,
        mode: HermesDomainCoreMode,
        nativeStatus: () -> DomainCoreRuntimeNativeStatus,
        coreVersion: () -> String,
        legacy: () throws -> Data,
        rust: () throws -> Data,
        recordComparison: (DomainCoreShadowComparison) -> Void
    ) throws -> Data {
        try DomainCoreShadowRuntime.select(
            domain: "hermes",
            slice: slice(for: operation),
            operation: operation,
            mode: DomainCoreBuildMode(rawValue: mode.rawValue) ?? .legacy,
            nativeStatus: nativeStatus,
            coreVersion: coreVersion,
            legacy: legacy,
            rust: rust,
            equivalent: ==,
            nativeUnavailableError: HermesDomainCoreAdapterError.nativeUnavailable,
            diagnostic: diagnostic,
            recordComparison: recordComparison
        )
    }

    private static func diagnostic(_ operation: String, _ outcome: String) {
        NSLog("domain_core.hermes.%@ %@", operation, outcome)
    }

    private static func slice(for operation: String) -> String {
        operation == "aad" ? "aad" : operation.contains("hpke") ? "hpke-info" : "payload-keywrap"
    }

    static func nativeStatus() -> DomainCoreRuntimeNativeStatus {
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

    static func currentCoreVersion() -> String {
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
