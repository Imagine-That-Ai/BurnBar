import Foundation

/// Is the local Hermes gateway actually listening?
///
/// The Flame refuses to route Hermes work to a machine whose gateway is down,
/// which only means something if somebody checks. The daemon has no Hermes
/// client, so it asks the cheapest question that has a truthful answer: is
/// anything accepting connections on the gateway's loopback port.
///
/// A loopback TCP connect is sub-millisecond and needs no HTTP stack, so the
/// fleet provider can ask on every routing decision instead of trusting a value
/// captured when the daemon started.
public struct HermesGatewayProbe: Sendable {
    /// `hermes webapi`'s default port (see `DESIGN.md` § Hermes Integration).
    public static let defaultPort: UInt16 = 8642

    private let port: UInt16

    public init(port: UInt16 = HermesGatewayProbe.defaultPort) {
        self.port = port
    }

    public func isReachable() -> Bool {
        Self.isListening(onLoopbackPort: port)
    }

    /// True when a TCP connect to `127.0.0.1:<port>` succeeds immediately.
    ///
    /// Loopback connects either complete or are refused within the kernel, so
    /// this does not block on network timeouts. A socket that reports
    /// `EINPROGRESS` is treated as *not* reachable rather than waited on: an
    /// answer this function cannot give instantly is an answer the caller
    /// should not be blocked for.
    static func isListening(onLoopbackPort port: UInt16) -> Bool {
        // Glibc types the SOCK_* constants as `__socket_type`; Darwin types
        // them as the `Int32` that `socket(_:_:_:)` wants.
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var flags = fcntl(descriptor, F_GETFL, 0)
        flags |= O_NONBLOCK
        guard fcntl(descriptor, F_SETFL, flags) >= 0 else { return false }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
