import Darwin
import Foundation

protocol GrokDPortProbing: Sendable {
    func isListening(host: String, port: UInt16) -> Bool
}

/// Non-blocking TCP connect to `127.0.0.1`. Never resolves `localhost`.
struct GrokDTCPPortProbe: GrokDPortProbing {
    var timeoutMilliseconds: Int32 = 250

    func isListening(host: String, port: UInt16) -> Bool {
        guard host == GrokDHostConfig.loopbackHost else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(host))

        let rc: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.connect(fd, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let selected = Darwin.poll(&pfd, 1, timeoutMilliseconds)
        guard selected > 0, (pfd.revents & Int16(POLLOUT)) != 0 else { return false }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let got = Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return got == 0 && soError == 0
    }
}
