import Dispatch

enum DomainCoreQuotaShadowTiming {
    static func measure<T>(_ body: () throws -> T) rethrows -> (value: T, micros: UInt64) {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        return (value, elapsed / 1_000)
    }

    static func measureResult<T>(_ body: () throws -> T) -> (result: Result<T, Error>, micros: UInt64) {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = Result { try body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        return (result, elapsed / 1_000)
    }
}

enum DomainCoreQuotaShadowProbeError: Error {
    case nativeUnavailable
}

enum DomainCoreQuotaShadowCategory {
    static func classify<Value>(
        _ result: Result<(Value, Bool), Error>,
        equivalent: (Value) -> Bool
    ) -> DomainCoreQuotaShadowMismatchCategory? {
        switch result {
        case let .success((value, invalid)):
            if invalid { return .invalidResult }
            return equivalent(value) ? nil : .resultMismatch
        case let .failure(error):
            return error is DomainCoreQuotaShadowProbeError ? .nativeUnavailable : .nativeError
        }
    }
}
