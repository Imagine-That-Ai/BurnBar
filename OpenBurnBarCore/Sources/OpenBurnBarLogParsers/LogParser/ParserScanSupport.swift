import Foundation
import OpenBurnBarParserSupport

// Keep the parser module's historical public surface stable while the shared
// read gate, options, and scan primitives live in the lower-level support leaf.
public typealias LogParseOptions = OpenBurnBarParserSupport.LogParseOptions
public typealias ParserFileReadGate = OpenBurnBarParserSupport.ParserFileReadGate
public typealias ParserDiscoveredFile = OpenBurnBarParserSupport.ParserDiscoveredFile
public typealias ParserFileDiscoveryTracker = OpenBurnBarParserSupport.ParserFileDiscoveryTracker
public typealias ParserDeferredReason = OpenBurnBarParserSupport.ParserDeferredReason
public typealias ParserPassMetricSnapshot = OpenBurnBarParserSupport.ParserPassMetricSnapshot
public typealias ParserPassMetrics = OpenBurnBarParserSupport.ParserPassMetrics
public typealias ParserResourceLimits = OpenBurnBarParserSupport.ParserResourceLimits
public typealias ParserResourceExceeded = OpenBurnBarParserSupport.ParserResourceExceeded
public typealias ParserResourceGovernor = OpenBurnBarParserSupport.ParserResourceGovernor
public typealias ParserScanDigest = OpenBurnBarParserSupport.ParserScanDigest

@inlinable
public func parserAutoReleasePool<Result>(
    _ body: () throws -> Result
) rethrows -> Result {
    try OpenBurnBarParserSupport.parserAutoReleasePool(body)
}
