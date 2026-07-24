import Foundation

/// Runs `body` inside an autorelease pool and returns its result unchanged.
///
/// Parser hot paths (e.g. `headDigestHex`, `BufferedLineReader`) allocate
/// short-lived Foundation objects per line; pooling them keeps peak memory
/// flat on multi-hundred-megabyte session logs. The wrapper exists so call
/// sites share one contract: the body runs exactly once, its return value
/// (including optionals) reaches the caller untouched, and thrown errors
/// propagate unaltered.
func parserAutoReleasePool<T>(_ body: () throws -> T) rethrows -> T {
    try autoreleasepool(invoking: body)
}
