import Foundation

public struct DomainCoreShadowComparison: Equatable, Sendable {
    public let domain: String
    public let slice: String
    public let operation: String
    public let coreVersion: String
    public let outcome: String
    public let mismatchCategory: String?
    public let legacyMicros: UInt64
    public let rustMicros: UInt64

    public init(
        domain: String,
        slice: String,
        operation: String,
        coreVersion: String,
        outcome: String,
        mismatchCategory: String?,
        legacyMicros: UInt64,
        rustMicros: UInt64
    ) {
        self.domain = domain
        self.slice = slice
        self.operation = operation
        self.coreVersion = coreVersion
        self.outcome = outcome
        self.mismatchCategory = mismatchCategory
        self.legacyMicros = legacyMicros
        self.rustMicros = rustMicros
    }
}

public enum DomainCoreShadowComparisonCollector {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (DomainCoreShadowComparison) -> Void)?

    public static func configure(_ value: (@Sendable (DomainCoreShadowComparison) -> Void)?) {
        lock.lock()
        sink = value
        lock.unlock()
    }

    public static func record(_ comparison: DomainCoreShadowComparison) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?(comparison)
    }
}
