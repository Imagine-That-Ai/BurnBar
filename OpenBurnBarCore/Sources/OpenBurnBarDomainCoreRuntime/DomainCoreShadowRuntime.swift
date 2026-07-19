import Dispatch
import Foundation

public enum DomainCoreRuntimeNativeStatus: Equatable, Sendable {
    case available
    case unavailable(coreVersion: String, mismatchCategory: String)
}

public enum DomainCoreShadowRuntime {
    public static func select<Value>(
        domain: String,
        slice: String,
        operation: String,
        mode: DomainCoreBuildMode,
        nativeStatus: () -> DomainCoreRuntimeNativeStatus,
        coreVersion: () -> String,
        legacy: () throws -> Value,
        rust: () throws -> Value,
        equivalent: (Value, Value) -> Bool,
        nativeUnavailableError: @autoclosure () -> any Error,
        diagnostic: (String, String) -> Void = { _, _ in },
        recordComparison: (DomainCoreShadowComparison) -> Void = DomainCoreShadowComparisonCollector.record
    ) throws -> Value {
        guard mode != .legacy else { return try legacy() }
        guard mode == .shadow else {
            guard nativeStatus() == .available else { throw nativeUnavailableError() }
            return try rust()
        }

        let legacyStarted = DispatchTime.now().uptimeNanoseconds
        let old = try legacy()
        let legacyMicros = elapsedMicros(since: legacyStarted)
        switch nativeStatus() {
        case .available:
            break
        case let .unavailable(unavailableCoreVersion, mismatchCategory):
            diagnostic(operation, mismatchCategory == "native_error" ? "abi_mismatch" : "native_unavailable")
            recordComparison(.init(
                domain: domain,
                slice: slice,
                operation: operation,
                coreVersion: unavailableCoreVersion,
                outcome: "mismatch",
                mismatchCategory: mismatchCategory,
                legacyMicros: legacyMicros,
                rustMicros: 0
            ))
            return old
        }

        let comparisonCoreVersion = coreVersion()
        let rustStarted = DispatchTime.now().uptimeNanoseconds
        let value: Value
        do {
            value = try rust()
        } catch {
            diagnostic(operation, "native_error")
            recordComparison(.init(
                domain: domain,
                slice: slice,
                operation: operation,
                coreVersion: comparisonCoreVersion,
                outcome: "mismatch",
                mismatchCategory: "native_error",
                legacyMicros: legacyMicros,
                rustMicros: elapsedMicros(since: rustStarted)
            ))
            return old
        }

        let matches = equivalent(old, value)
        if !matches { diagnostic(operation, "shadow_mismatch") }
        recordComparison(.init(
            domain: domain,
            slice: slice,
            operation: operation,
            coreVersion: comparisonCoreVersion,
            outcome: matches ? "match" : "mismatch",
            mismatchCategory: matches ? nil : "result_mismatch",
            legacyMicros: legacyMicros,
            rustMicros: elapsedMicros(since: rustStarted)
        ))
        return old
    }

    public static func selectVerifiedLegacy<Value>(
        domain: String,
        slice: String,
        operation: String,
        mode: DomainCoreBuildMode,
        nativeStatus: () -> DomainCoreRuntimeNativeStatus,
        coreVersion: () -> String,
        legacy: () throws -> Value,
        rustAuthority: () throws -> Value,
        verifyLegacyWithRust: (Value) throws -> Bool,
        nativeUnavailableError: @autoclosure () -> any Error,
        diagnostic: (String, String) -> Void = { _, _ in },
        recordComparison: (DomainCoreShadowComparison) -> Void = DomainCoreShadowComparisonCollector.record
    ) throws -> Value {
        guard mode != .legacy else { return try legacy() }
        guard mode == .shadow else {
            guard nativeStatus() == .available else { throw nativeUnavailableError() }
            return try rustAuthority()
        }

        let legacyStarted = DispatchTime.now().uptimeNanoseconds
        let old = try legacy()
        let legacyMicros = elapsedMicros(since: legacyStarted)
        switch nativeStatus() {
        case .available:
            break
        case let .unavailable(unavailableCoreVersion, mismatchCategory):
            diagnostic(operation, mismatchCategory == "native_error" ? "abi_mismatch" : "native_unavailable")
            recordComparison(.init(
                domain: domain,
                slice: slice,
                operation: operation,
                coreVersion: unavailableCoreVersion,
                outcome: "mismatch",
                mismatchCategory: mismatchCategory,
                legacyMicros: legacyMicros,
                rustMicros: 0
            ))
            return old
        }

        let comparisonCoreVersion = coreVersion()
        let rustStarted = DispatchTime.now().uptimeNanoseconds
        let matches: Bool
        do {
            matches = try verifyLegacyWithRust(old)
        } catch {
            diagnostic(operation, "native_error")
            recordComparison(.init(
                domain: domain,
                slice: slice,
                operation: operation,
                coreVersion: comparisonCoreVersion,
                outcome: "mismatch",
                mismatchCategory: "native_error",
                legacyMicros: legacyMicros,
                rustMicros: elapsedMicros(since: rustStarted)
            ))
            return old
        }

        if !matches { diagnostic(operation, "shadow_mismatch") }
        recordComparison(.init(
            domain: domain,
            slice: slice,
            operation: operation,
            coreVersion: comparisonCoreVersion,
            outcome: matches ? "match" : "mismatch",
            mismatchCategory: matches ? nil : "result_mismatch",
            legacyMicros: legacyMicros,
            rustMicros: elapsedMicros(since: rustStarted)
        ))
        return old
    }

    private static func elapsedMicros(since started: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNanoseconds = now >= started ? now - started : 0
        return min(600_000_000, elapsedNanoseconds / 1_000)
    }
}
