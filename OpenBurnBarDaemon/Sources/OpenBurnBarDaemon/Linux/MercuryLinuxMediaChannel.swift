#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarMedia

public final class MercuryLinuxMediaChannel: @unchecked Sendable {
    public enum ChannelError: Error, LocalizedError, Equatable {
        case runtimeDirectoryUnavailable
        case socketPathTooLong(String)
        case socketFailed(Int32)
        case bindFailed(String, Int32)
        case listenFailed(String, Int32)
        case chmodFailed(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .runtimeDirectoryUnavailable:
                return "XDG_RUNTIME_DIR is not set; cannot create openburnbar-media.sock."
            case .socketPathTooLong(let path):
                return "Mercury Linux media socket path exceeds sockaddr_un capacity: \(path)"
            case .socketFailed(let code):
                return "Failed to create Mercury Linux media socket: errno \(code)."
            case .bindFailed(let path, let code):
                return "Failed to bind Mercury Linux media socket at \(path): errno \(code)."
            case .listenFailed(let path, let code):
                return "Failed to listen on Mercury Linux media socket at \(path): errno \(code)."
            case .chmodFailed(let path, let code):
                return "Failed to chmod Mercury Linux media socket at \(path): errno \(code)."
            }
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var socketPath: String
        public var isRunning: Bool
        public var shellConnected: Bool
        public var queuedFrameCount: Int
        public var droppedFrameCount: Int
    }

    public static var defaultSocketPath: String? {
        guard let runtimeDirectory = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !runtimeDirectory.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
            .appendingPathComponent("openburnbar-media.sock")
            .path
    }

    private let condition = NSCondition()
    private let maxQueuedFrames: Int
    private var socketPath: String
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var queue: [Data] = []
    private var droppedFrames: Int = 0
    private var running = false
    private var acceptTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?

    public init(
        socketPath: String? = MercuryLinuxMediaChannel.defaultSocketPath,
        maxQueuedFrames: Int = 8
    ) throws {
        guard let socketPath, !socketPath.isEmpty else {
            throw ChannelError.runtimeDirectoryUnavailable
        }
        self.socketPath = socketPath
        self.maxQueuedFrames = max(1, maxQueuedFrames)
    }

    deinit {
        stop()
    }

    public func start() throws {
        condition.lock()
        if running {
            condition.unlock()
            return
        }
        condition.unlock()

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketPath)

        let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else {
            throw ChannelError.socketFailed(errno)
        }

        do {
            try bindUnixSocket(fd: fd, path: socketPath)
            guard Glibc.listen(fd, SOMAXCONN) == 0 else {
                throw ChannelError.listenFailed(socketPath, errno)
            }
            guard Glibc.chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                throw ChannelError.chmodFailed(socketPath, errno)
            }
        } catch {
            close(fd)
            unlink(socketPath)
            throw error
        }

        condition.lock()
        listenFD = fd
        running = true
        condition.broadcast()
        condition.unlock()

        acceptTask = Task.detached(priority: .utility) { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
        writerTask = Task.detached(priority: .utility) { [weak self] in
            self?.writerLoop()
        }
    }

    public func stop() {
        condition.lock()
        guard running || listenFD >= 0 || clientFD >= 0 else {
            condition.unlock()
            return
        }
        running = false
        let oldListenFD = listenFD
        let oldClientFD = clientFD
        listenFD = -1
        clientFD = -1
        queue.removeAll()
        condition.broadcast()
        condition.unlock()

        acceptTask?.cancel()
        writerTask?.cancel()
        acceptTask = nil
        writerTask = nil

        if oldListenFD >= 0 {
            _ = Glibc.shutdown(oldListenFD, Int32(SHUT_RDWR))
            close(oldListenFD)
        }
        if oldClientFD >= 0 {
            _ = Glibc.shutdown(oldClientFD, Int32(SHUT_RDWR))
            close(oldClientFD)
        }
        unlink(socketPath)
    }

    @discardableResult
    public func offer(_ frame: MediaFrame) -> Bool {
        let packet = Self.encodeShellFrame(frame)
        condition.lock()
        defer {
            condition.signal()
            condition.unlock()
        }
        guard running else {
            droppedFrames += 1
            return false
        }
        if queue.count >= maxQueuedFrames {
            if frame.flags.contains(.keyframe), let removable = queue.indices.first {
                queue.remove(at: removable)
            } else {
                droppedFrames += 1
                return false
            }
        }
        queue.append(packet)
        return true
    }

    public func snapshot() -> Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(
            socketPath: socketPath,
            isRunning: running,
            shellConnected: clientFD >= 0,
            queuedFrameCount: queue.count,
            droppedFrameCount: droppedFrames
        )
    }

    public static func encodeShellFrame(_ frame: MediaFrame) -> Data {
        let bodyLength = 1 + 1 + 8 + frame.payload.count
        var data = Data(capacity: 4 + bodyLength)
        appendUInt32BE(UInt32(bodyLength), to: &data)
        data.append(frame.kind.rawValue)
        data.append(frame.flags.rawValue)
        appendUInt64BE(frame.presentationTimestampMillis, to: &data)
        data.append(frame.payload)
        return data
    }

    private func acceptLoop(listenFD: Int32) {
        while true {
            condition.lock()
            let shouldRun = running
            condition.unlock()
            if !shouldRun || Task.isCancelled { break }

            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                break
            }

            condition.lock()
            let previous = clientFD
            clientFD = fd
            condition.broadcast()
            condition.unlock()
            if previous >= 0 {
                _ = Glibc.shutdown(previous, Int32(SHUT_RDWR))
                close(previous)
            }
        }
    }

    private func writerLoop() {
        while true {
            condition.lock()
            while running && (clientFD < 0 || queue.isEmpty) {
                condition.wait()
            }
            if !running || Task.isCancelled {
                condition.unlock()
                break
            }
            let fd = clientFD
            let packet = queue.removeFirst()
            condition.unlock()

            if !Self.writeAll(packet, to: fd) {
                condition.lock()
                if clientFD == fd {
                    clientFD = -1
                }
                condition.unlock()
                _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
                close(fd)
            }
        }
    }

    private func bindUnixSocket(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let maxPathBytes = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathBytes else {
            throw ChannelError.socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw ChannelError.bindFailed(path, errno)
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            while offset < data.count {
                let written = Glibc.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64BE(_ value: UInt64, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

}
#endif
