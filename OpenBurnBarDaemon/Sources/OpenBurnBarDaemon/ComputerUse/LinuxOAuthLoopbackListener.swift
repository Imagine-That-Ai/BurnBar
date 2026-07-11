#if os(Linux)
import Foundation
import Glibc

enum LinuxOAuthLoopbackError: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case cancelled
    case invalidRequest
}

/// Single-use loopback HTTP listener for RFC 8252 desktop OAuth callbacks.
/// It binds only 127.0.0.1, accepts one bounded GET, and never logs the URL.
final class LinuxOAuthLoopbackListener: @unchecked Sendable {
    let port: Int
    let callbackPath: String
    private let expectedState: String

    private let lock = NSLock()
    private var descriptor: Int32
    private var cancelled = false

    init(expectedState: String, callbackPath: String = "/callback") throws {
        guard callbackPath.hasPrefix("/"), callbackPath.utf8.count <= 128,
              expectedState.isEmpty == false, expectedState.utf8.count <= 256 else {
            throw LinuxOAuthLoopbackError.invalidRequest
        }
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw LinuxOAuthLoopbackError.unavailable }
        var closeOnFailure = true
        defer { if closeOnFailure { _ = Glibc.close(fd) } }

        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            throw LinuxOAuthLoopbackError.unavailable
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Glibc.listen(fd, 1) == 0 else {
            throw LinuxOAuthLoopbackError.unavailable
        }
        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        guard nameResult == 0 else { throw LinuxOAuthLoopbackError.unavailable }

        descriptor = fd
        port = Int(UInt16(bigEndian: bound.sin_port))
        self.callbackPath = callbackPath
        self.expectedState = expectedState
        closeOnFailure = false
    }

    deinit { cancel() }

    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        let fd = lock.withLock { descriptor }
        guard fd >= 0 else { throw LinuxOAuthLoopbackError.cancelled }
        return try await Task.detached(priority: .utility) { [weak self] in
            guard let self else { throw LinuxOAuthLoopbackError.cancelled }
            return try self.blockingWait(fd: fd, timeout: timeout)
        }.value
    }

    func cancel() {
        let fd: Int32 = lock.withLock {
            cancelled = true
            let current = descriptor
            descriptor = -1
            return current
        }
        if fd >= 0 {
            _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
            _ = Glibc.close(fd)
        }
    }

    private func blockingWait(fd: Int32, timeout: TimeInterval) throws -> URL {
        defer { cancel() }
        let deadline = Date().addingTimeInterval(max(1, timeout))
        var rejectedRequests = 0
        while Date() < deadline {
            if lock.withLock({ cancelled }) { throw LinuxOAuthLoopbackError.cancelled }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Glibc.poll(&pollDescriptor, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw LinuxOAuthLoopbackError.unavailable
            }
            guard result > 0 else { continue }
            if pollDescriptor.revents & Int16(POLLIN) != 0 {
                if let callback = try acceptAndRead(fd: fd, deadline: deadline) {
                    return callback
                }
                rejectedRequests += 1
                if rejectedRequests >= 32 { throw LinuxOAuthLoopbackError.invalidRequest }
                continue
            }
            if pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw lock.withLock({ cancelled })
                    ? LinuxOAuthLoopbackError.cancelled
                    : LinuxOAuthLoopbackError.unavailable
            }
        }
        throw LinuxOAuthLoopbackError.timedOut
    }

    private func acceptAndRead(fd: Int32, deadline: Date) throws -> URL? {
        let client = Glibc.accept(fd, nil, nil)
        guard client >= 0 else { throw LinuxOAuthLoopbackError.unavailable }
        defer { _ = Glibc.close(client) }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while request.count < 16 * 1_024, Date() < deadline {
            var pollDescriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let pollResult = Glibc.poll(&pollDescriptor, 1, 100)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw LinuxOAuthLoopbackError.invalidRequest
            }
            guard pollResult > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Glibc.recv(client, bytes.baseAddress, bytes.count, 0)
            }
            guard count > 0 else { throw LinuxOAuthLoopbackError.invalidRequest }
            request.append(contentsOf: buffer.prefix(Int(count)))
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard request.count <= 16 * 1_024,
              let header = String(data: request, encoding: .utf8),
              let firstLine = header.components(separatedBy: "\r\n").first else {
            throw LinuxOAuthLoopbackError.invalidRequest
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])"),
              url.path == callbackPath else {
            sendResult(client: client, success: false)
            return nil
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = items.filter { $0.name == "state" }.compactMap(\.value)
        guard states.count == 1, states[0] == expectedState else {
            sendResult(client: client, success: false)
            return nil
        }
        if items.contains(where: { $0.name == "error" && $0.value == "access_denied" }) {
            sendResult(client: client, success: false)
            throw LinuxOAuthLoopbackError.cancelled
        }
        let codes = items.filter { $0.name == "code" }.compactMap(\.value)
        guard codes.count == 1,
              codes[0].isEmpty == false,
              codes[0].utf8.count <= 4_096 else {
            sendResult(client: client, success: false)
            return nil
        }
        sendResult(client: client, success: true)
        return url
    }

    private func sendResult(client: Int32, success: Bool) {
        let title = success ? "Signed in to OpenBurnBar" : "OpenBurnBar sign-in failed"
        let body = "<!doctype html><meta charset=utf-8><title>\(title)</title><h1>\(title)</h1><p>You can close this window.</p>"
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        response.withCString { pointer in
            _ = Glibc.send(client, pointer, strlen(pointer), Int32(MSG_NOSIGNAL))
        }
    }
}
#endif
