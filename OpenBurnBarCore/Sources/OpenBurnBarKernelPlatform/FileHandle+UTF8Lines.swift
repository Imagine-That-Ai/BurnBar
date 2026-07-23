import Foundation

// MARK: - FileHandle UTF-8 Line Reader

extension FileHandle {
    /// Buffered UTF-8 line reader for log files. Returns a lazy sequence so
    /// callers do not load and split multi-megabyte logs into memory at startup.
    ///
    /// Phase-2 WS-K W1 (docs/CORE_DECOMPOSITION_PROGRAM.md): this generic UTF-8
    /// line primitive — and its `BufferedLineSequence` return type — moved DOWN
    /// from `OpenBurnBarLogParsers/LogParser/LogParserProtocol.swift` into this
    /// leaf so it is reachable without the `OpenBurnBarLogParsers` dependency.
    /// Every existing caller resolves it unchanged: `OpenBurnBarLogParsers`,
    /// `OpenBurnBarQuota`, and the app targets all reach it transitively through
    /// `OpenBurnBarKernel`'s `@_exported import OpenBurnBarKernelPlatform`.
    public func readAllUTF8Lines() -> BufferedLineSequence {
        BufferedLineSequence(fileHandle: self)
    }
}
