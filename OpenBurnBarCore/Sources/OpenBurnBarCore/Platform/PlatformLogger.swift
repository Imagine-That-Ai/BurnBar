import Foundation
#if canImport(OSLog)
import OSLog
#endif

public enum PlatformLogLevel: String, Sendable {
    case debug
    case info
    case notice
    case error
}

public struct PlatformLogger: Sendable {
    public typealias Sink = @Sendable (
        _ level: PlatformLogLevel,
        _ subsystem: String,
        _ category: String,
        _ message: String
    ) -> Void

    private let subsystem: String
    private let category: String
    #if canImport(OSLog)
    private let logger: Logger
    #endif

    public nonisolated(unsafe) static var sink: Sink = { level, subsystem, category, message in
        #if canImport(OSLog)
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
        #else
        let line = "[\(level.rawValue)] \(subsystem)/\(category): \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        #endif
    }

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        #if canImport(OSLog)
        self.logger = Logger(subsystem: subsystem, category: category)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) {
        Self.sink(.debug, subsystem, category, message())
    }

    public func info(_ message: @autoclosure () -> String) {
        Self.sink(.info, subsystem, category, message())
    }

    public func notice(_ message: @autoclosure () -> String) {
        Self.sink(.notice, subsystem, category, message())
    }

    public func error(_ message: @autoclosure () -> String) {
        Self.sink(.error, subsystem, category, message())
    }
}
