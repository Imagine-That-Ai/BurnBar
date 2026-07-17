import Foundation
import OpenBurnBarDomainCoreRuntime
import OpenBurnBarKernel

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

/// Stable Pensieve vector facade. The CloudVault build profile selects legacy,
/// shadow comparison, or Rust authority without exposing that choice to callers.
public enum PensieveVectorCloak {
    public static let embeddingModelVersion = "bge-small-en-v1.5-vault-dedup-v1"
    public static let deterministicModelVersion = "hashing-bow-v1"
    public static let embeddingDim = 384
    public static let bgeQueryInstruction = "Represent this sentence for searching relevant passages: "

    private static var mode: DomainCoreBuildMode {
        DomainCoreBuildProfileResolver.mode(for: .cloudVault)
    }

    public static func cloak(
        _ vector: [Double],
        vaultKey: Data,
        modelVersion: String = embeddingModelVersion
    ) throws -> [Double] {
        let legacy = { try PensieveVectorLegacy.cloak(vector, vaultKey: vaultKey, modelVersion: modelVersion) }
        switch mode {
        case .legacy:
            return try legacy()
        case .rust:
            return try nativeCloak(vector, vaultKey: vaultKey, modelVersion: modelVersion)
        case .shadow:
            let legacyStarted = Date.timeIntervalSinceReferenceDate
            let legacyValue = try legacy()
            let legacyMicros = elapsedMicros(since: legacyStarted)
            let rustStarted = Date.timeIntervalSinceReferenceDate
            do {
                let rustValue = try nativeCloak(vector, vaultKey: vaultKey, modelVersion: modelVersion)
                let matches = equivalent(legacyValue, rustValue)
                recordComparison(
                    operation: "pensieve_vector_cloak",
                    matches: matches,
                    category: matches ? nil : "result_mismatch",
                    legacyMicros: legacyMicros,
                    rustMicros: elapsedMicros(since: rustStarted)
                )
                if !matches {
                    PlatformLogger(subsystem: "com.openburnbar.core", category: "PensieveVectorDomainCore")
                        .warning("domain_core.pensieve_vector shadow_mismatch operation=pensieve_vector_cloak core=abi3")
                }
            } catch {
                recordComparison(
                    operation: "pensieve_vector_cloak",
                    matches: false,
                    category: "native_error",
                    legacyMicros: legacyMicros,
                    rustMicros: elapsedMicros(since: rustStarted)
                )
                PlatformLogger(subsystem: "com.openburnbar.core", category: "PensieveVectorDomainCore")
                    .warning("domain_core.pensieve_vector native_error operation=pensieve_vector_cloak core=abi3")
            }
            return legacyValue
        }
    }

    public static func l2normalize(_ vector: [Double]) -> [Double] {
        let legacy = { legacyNormalize(vector) }
        switch mode {
        case .legacy:
            return legacy()
        case .rust:
            do { return try nativeNormalize(vector) } catch {
                preconditionFailure("Rust-authoritative Pensieve normalization failed: \(error)")
            }
        case .shadow:
            let legacyStarted = Date.timeIntervalSinceReferenceDate
            let legacyValue = legacy()
            let legacyMicros = elapsedMicros(since: legacyStarted)
            let rustStarted = Date.timeIntervalSinceReferenceDate
            do {
                let rustValue = try nativeNormalize(vector)
                let matches = equivalent(legacyValue, rustValue)
                recordComparison(
                    operation: "pensieve_l2_normalize",
                    matches: matches,
                    category: matches ? nil : "result_mismatch",
                    legacyMicros: legacyMicros,
                    rustMicros: elapsedMicros(since: rustStarted)
                )
                if !matches {
                    PlatformLogger(subsystem: "com.openburnbar.core", category: "PensieveVectorDomainCore")
                        .warning("domain_core.pensieve_vector shadow_mismatch operation=pensieve_l2_normalize core=abi3")
                }
            } catch {
                recordComparison(
                    operation: "pensieve_l2_normalize",
                    matches: false,
                    category: "native_error",
                    legacyMicros: legacyMicros,
                    rustMicros: elapsedMicros(since: rustStarted)
                )
                PlatformLogger(subsystem: "com.openburnbar.core", category: "PensieveVectorDomainCore")
                    .warning("domain_core.pensieve_vector native_error operation=pensieve_l2_normalize core=abi3")
            }
            return legacyValue
        }
    }

    public static func deterministicEmbed(_ text: String, isQuery: Bool = false) -> [Double] {
        let legacy = { PensieveVectorLegacy.deterministicEmbed(text, isQuery: isQuery) }
        switch mode {
        case .legacy:
            return legacy()
        case .rust:
            do { return try nativeEmbed(text, isQuery: isQuery) } catch {
                preconditionFailure("Rust-authoritative Pensieve embedding failed: \(error)")
            }
        case .shadow:
            let legacyStarted = Date.timeIntervalSinceReferenceDate
            let legacyValue = legacy()
            let legacyMicros = elapsedMicros(since: legacyStarted)
            let rustStarted = Date.timeIntervalSinceReferenceDate
            do {
                let rustValue = try nativeEmbed(text, isQuery: isQuery)
                let matches = equivalent(legacyValue, rustValue)
                recordComparison(
                    operation: "pensieve_deterministic_embed",
                    matches: matches,
                    category: matches ? nil : "result_mismatch",
                    legacyMicros: legacyMicros,
                    rustMicros: elapsedMicros(since: rustStarted)
                )
                if !matches {
                    PlatformLogger(subsystem: "com.openburnbar.core", category: "PensieveVectorDomainCore")
                        .warning("domain_core.pensieve_vector shadow_mismatch operation=pensieve_deterministic_embed core=abi3")
                }
            } catch {
                recordComparison(
                    operation: "pensieve_deterministic_embed",
                    matches: false,
                    category: "native_error",
                    legacyMicros: legacyMicros,
                    rustMicros: elapsedMicros(since: rustStarted)
                )
                PlatformLogger(subsystem: "com.openburnbar.core", category: "PensieveVectorDomainCore")
                    .warning("domain_core.pensieve_vector native_error operation=pensieve_deterministic_embed core=abi3")
            }
            return legacyValue
        }
    }

    public static func embedAndCloak(
        _ text: String,
        vaultKey: Data,
        isQuery: Bool = false,
        modelVersion: String = deterministicModelVersion
    ) throws -> (modelVersion: String, vector: [Double]) {
        let legacy = {
            try PensieveVectorLegacy.embedAndCloak(
                text,
                vaultKey: vaultKey,
                isQuery: isQuery,
                modelVersion: modelVersion
            )
        }
        switch mode {
        case .legacy:
            return try legacy()
        case .rust:
            return (modelVersion, try nativeEmbedAndCloak(
                text, vaultKey: vaultKey, isQuery: isQuery, modelVersion: modelVersion
            ))
        case .shadow:
            let legacyStarted = Date.timeIntervalSinceReferenceDate
            let legacyValue = try legacy()
            let legacyMicros = elapsedMicros(since: legacyStarted)
            let rustStarted = Date.timeIntervalSinceReferenceDate
            do {
                let rustVector = try nativeEmbedAndCloak(
                    text, vaultKey: vaultKey, isQuery: isQuery, modelVersion: modelVersion
                )
                let matches = equivalent(legacyValue.vector, rustVector)
                recordComparison(
                    operation: "pensieve_deterministic_embed_and_cloak",
                    matches: matches,
                    category: matches ? nil : "result_mismatch",
                    legacyMicros: legacyMicros,
                    rustMicros: elapsedMicros(since: rustStarted)
                )
                if !matches {
                    PlatformLogger(subsystem: "com.openburnbar.core", category: "PensieveVectorDomainCore")
                        .warning("domain_core.pensieve_vector shadow_mismatch operation=pensieve_deterministic_embed_and_cloak core=abi3")
                }
            } catch {
                recordComparison(
                    operation: "pensieve_deterministic_embed_and_cloak",
                    matches: false,
                    category: "native_error",
                    legacyMicros: legacyMicros,
                    rustMicros: elapsedMicros(since: rustStarted)
                )
                PlatformLogger(subsystem: "com.openburnbar.core", category: "PensieveVectorDomainCore")
                    .warning("domain_core.pensieve_vector native_error operation=pensieve_deterministic_embed_and_cloak core=abi3")
            }
            return legacyValue
        }
    }

    private static func nativeCloak(
        _ vector: [Double], vaultKey: Data, modelVersion: String
    ) throws -> [Double] {
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard DomainCoreNativeProbe.abiVersion() == 3 else {
            throw PensieveVectorDomainCoreError.nativeUnavailable
        }
        return try OpenBurnBarDomainCoreFFI.pensieveVectorCloak(
            vector: vector, vaultKey: vaultKey, modelVersion: modelVersion
        )
        #else
        throw PensieveVectorDomainCoreError.nativeUnavailable
        #endif
    }

    private static func nativeNormalize(_ vector: [Double]) throws -> [Double] {
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard DomainCoreNativeProbe.abiVersion() == 3 else {
            throw PensieveVectorDomainCoreError.nativeUnavailable
        }
        return try OpenBurnBarDomainCoreFFI.pensieveL2Normalize(vector: vector)
        #else
        throw PensieveVectorDomainCoreError.nativeUnavailable
        #endif
    }

    private static func nativeEmbed(_ text: String, isQuery: Bool) throws -> [Double] {
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard DomainCoreNativeProbe.abiVersion() == 3 else {
            throw PensieveVectorDomainCoreError.nativeUnavailable
        }
        return try OpenBurnBarDomainCoreFFI.pensieveDeterministicEmbed(
            text: text, dimensions: UInt32(embeddingDim), isQuery: isQuery
        )
        #else
        throw PensieveVectorDomainCoreError.nativeUnavailable
        #endif
    }

    private static func nativeEmbedAndCloak(
        _ text: String, vaultKey: Data, isQuery: Bool, modelVersion: String
    ) throws -> [Double] {
        #if canImport(OpenBurnBarDomainCoreFFI)
        guard DomainCoreNativeProbe.abiVersion() == 3 else {
            throw PensieveVectorDomainCoreError.nativeUnavailable
        }
        return try OpenBurnBarDomainCoreFFI.pensieveDeterministicEmbedAndCloak(
            text: text,
            dimensions: UInt32(embeddingDim),
            isQuery: isQuery,
            vaultKey: vaultKey,
            modelVersion: modelVersion
        )
        #else
        throw PensieveVectorDomainCoreError.nativeUnavailable
        #endif
    }

    private static func equivalent(_ left: [Double], _ right: [Double]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { abs($0 - $1) < 1e-12 }
    }

    private static func legacyNormalize(_ vector: [Double]) -> [Double] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private static func elapsedMicros(since started: TimeInterval) -> UInt64 {
        let micros = max(0, (Date.timeIntervalSinceReferenceDate - started) * 1_000_000)
        return UInt64(min(600_000_000, micros.rounded()))
    }

    private static func recordComparison(
        operation: String,
        matches: Bool,
        category: String?,
        legacyMicros: UInt64,
        rustMicros: UInt64
    ) {
        #if canImport(OpenBurnBarDomainCoreFFI)
        let coreVersion = OpenBurnBarDomainCoreFFI.domainCoreVersion()
        #else
        let coreVersion = "0.0.0-native-unavailable"
        #endif
        DomainCoreShadowComparisonCollector.record(.init(
            domain: "cloudvault",
            slice: "pensieve-vectors",
            operation: operation,
            coreVersion: coreVersion,
            outcome: matches ? "match" : "mismatch",
            mismatchCategory: category,
            legacyMicros: legacyMicros,
            rustMicros: rustMicros
        ))
    }

    #if DEBUG
    public static func resetReflectionCacheForTesting() {
        PensieveVectorLegacy.resetReflectionCacheForTesting()
    }
    #endif
}

private enum PensieveVectorDomainCoreError: Error {
    case nativeUnavailable
}
