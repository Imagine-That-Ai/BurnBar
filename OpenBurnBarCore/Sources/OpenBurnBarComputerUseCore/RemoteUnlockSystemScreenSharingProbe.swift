import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct RemoteUnlockSystemScreenSharingStatus: Sendable, Equatable {
    public var applicationAvailable: Bool
    public var loopbackListenerAvailable: Bool
    public var requiresLoopbackListener: Bool

    public init(
        applicationAvailable: Bool,
        loopbackListenerAvailable: Bool,
        requiresLoopbackListener: Bool
    ) {
        self.applicationAvailable = applicationAvailable
        self.loopbackListenerAvailable = loopbackListenerAvailable
        self.requiresLoopbackListener = requiresLoopbackListener
    }

    public var isAvailable: Bool {
        applicationAvailable && (!requiresLoopbackListener || loopbackListenerAvailable)
    }
}

public struct RemoteUnlockSystemScreenSharingProbe: Sendable {
    public static let remoteManagementAgentPath =
        "/System/Library/CoreServices/RemoteManagement/ARDAgent.app"
    public static let screenSharingAppPath =
        "/System/Applications/Utilities/Screen Sharing.app"
    public static let legacyScreenSharingAppPath =
        "/System/Library/CoreServices/Applications/Screen Sharing.app"
    public static let defaultLoopbackPort: UInt16 = 5900
    public static let defaultLoopbackTimeoutSeconds: TimeInterval = 0.2

    public var requiresLoopbackListener: Bool
    public var applicationPaths: [String]
    public var loopbackPort: UInt16
    public var loopbackTimeoutSeconds: TimeInterval
    public var fileExists: @Sendable (String) -> Bool
    public var canConnectLoopback: @Sendable (UInt16, TimeInterval) -> Bool

    public init(
        requiresLoopbackListener: Bool = true,
        applicationPaths: [String] = [
            Self.remoteManagementAgentPath,
            Self.screenSharingAppPath,
            Self.legacyScreenSharingAppPath
        ],
        loopbackPort: UInt16 = Self.defaultLoopbackPort,
        loopbackTimeoutSeconds: TimeInterval = Self.defaultLoopbackTimeoutSeconds,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        canConnectLoopback: @escaping @Sendable (UInt16, TimeInterval) -> Bool = { port, timeout in
            Self.canConnectLoopback(port: port, timeoutSeconds: timeout)
        }
    ) {
        self.requiresLoopbackListener = requiresLoopbackListener
        self.applicationPaths = applicationPaths
        self.loopbackPort = loopbackPort
        self.loopbackTimeoutSeconds = loopbackTimeoutSeconds
        self.fileExists = fileExists
        self.canConnectLoopback = canConnectLoopback
    }

    public func status() -> RemoteUnlockSystemScreenSharingStatus {
        let appAvailable = applicationPaths.contains { fileExists($0) }
        let listenerAvailable = canConnectLoopback(loopbackPort, loopbackTimeoutSeconds)
        return RemoteUnlockSystemScreenSharingStatus(
            applicationAvailable: appAvailable,
            loopbackListenerAvailable: listenerAvailable,
            requiresLoopbackListener: requiresLoopbackListener
        )
    }

    public static func canConnectLoopback(port: UInt16, timeoutSeconds: TimeInterval) -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return false
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        let timeoutMilliseconds = max(1, Int32((timeoutSeconds * 1_000).rounded(.up)))
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return false }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            fd,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0 else {
            return false
        }
        return socketError == 0
        #else
        return false
        #endif
    }
}
