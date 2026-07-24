// BurnBar Unix-domain socket helpers extracted from OpenBurnBarDaemonServer
// to keep the daemon server under the 2000-line shrink-only budget.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct BurnBarSocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(status: stat) {
        self.device = status.st_dev
        self.inode = status.st_ino
    }
}

struct BurnBarDaemonSocketOwnership {
    let lockFileDescriptor: Int32

    static func acquire(for socketPath: String) throws -> BurnBarDaemonSocketOwnership {
        let lockPath = socketPath + ".lock"
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1 else {
                throw BurnBarDaemonError.unexpectedExistingItem(lockPath)
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw BurnBarDaemonError.daemonAlreadyRunning(socketPath)
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            return BurnBarDaemonSocketOwnership(lockFileDescriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    func release() {
        _ = flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
    }
}

enum BurnBarUnixDomainSocket {
    static func ensureParentDirectory(for socketPath: String) throws {
        let socketURL = URL(fileURLWithPath: socketPath)
        let directoryURL = socketURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw BurnBarDaemonError.failedToCreateParentDirectory(directoryURL.path)
        }
    }

    static func preparePathForBind(at socketPath: String) throws -> Bool {
        var fileStatus = stat()
        let result = lstat(socketPath, &fileStatus)
        if result == -1 {
            if errno == ENOENT {
                return false
            }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let itemType = fileStatus.st_mode & S_IFMT
        guard itemType == S_IFSOCK else {
            throw BurnBarDaemonError.unexpectedExistingItem(socketPath)
        }

        if try isAcceptingConnections(at: socketPath) {
            throw BurnBarDaemonError.activeSocketAlreadyExists(socketPath)
        }

        let originalIdentity = BurnBarSocketIdentity(status: fileStatus)
        guard try removeSocket(at: socketPath, ifIdentityMatches: originalIdentity) else {
            throw BurnBarDaemonError.socketPathChanged(socketPath)
        }
        return true
    }

    static func socketIdentity(at socketPath: String) throws -> BurnBarSocketIdentity {
        var fileStatus = stat()
        guard lstat(socketPath, &fileStatus) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard fileStatus.st_mode & S_IFMT == S_IFSOCK else {
            throw BurnBarDaemonError.unexpectedExistingItem(socketPath)
        }
        return BurnBarSocketIdentity(status: fileStatus)
    }

    static func removeSocket(
        at socketPath: String,
        ifIdentityMatches expectedIdentity: BurnBarSocketIdentity
    ) throws -> Bool {
        var currentStatus = stat()
        guard lstat(socketPath, &currentStatus) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard currentStatus.st_mode & S_IFMT == S_IFSOCK else {
            return false
        }
        guard BurnBarSocketIdentity(status: currentStatus) == expectedIdentity else {
            return false
        }
        guard unlink(socketPath) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return true
    }

    static func isAcceptingConnections(at socketPath: String) throws -> Bool {
        #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_UNIX, socketType, 0)
        guard descriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var address = try makeSocketAddress(for: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(descriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        if result == 0 {
            return true
        }
        let code = errno
        if code == ECONNREFUSED || code == ENOENT {
            return false
        }
        throw POSIXError(.init(rawValue: code) ?? .EIO)
    }

    static func makeListeningSocket(at socketPath: String) throws -> Int32 {
        #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fileDescriptor = socket(AF_UNIX, socketType, 0)
        guard fileDescriptor != -1 else {
            throw BurnBarDaemonError.failedToCreateSocket(
                code: errno,
                detail: String(cString: strerror(errno))
            )
        }

        configureNoSigPipe(for: fileDescriptor)

        do {
            var address = try makeSocketAddress(for: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                    bind(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
                }
            }

            guard bindResult == 0 else {
                let code = errno
                throw BurnBarDaemonError.failedToBindSocket(
                    path: socketPath,
                    code: code,
                    detail: String(cString: strerror(code))
                )
            }

            guard listen(fileDescriptor, SOMAXCONN) == 0 else {
                let code = errno
                throw BurnBarDaemonError.failedToListen(
                    path: socketPath,
                    code: code,
                    detail: String(cString: strerror(code))
                )
            }

            return fileDescriptor
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    static func restrictSocketPermissions(at socketPath: String) throws {
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    static func readRequest(from fileDescriptor: Int32, maxBytes: Int) throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(4_096)

        // 64KB chunks: large requests (mission packets, simulator runs)
        // used to cost one read() syscall per KB.
        var chunk = [UInt8](repeating: 0, count: 65_536)

        while true {
            let bytesRead = read(fileDescriptor, &chunk, chunk.count)
            if bytesRead == 0 {
                break
            }

            if bytesRead < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }

            buffer.append(contentsOf: chunk.prefix(bytesRead))
            if buffer.count > maxBytes {
                throw BurnBarDaemonError.requestTooLarge(maxBytes)
            }

            if buffer.last == 0x0A {
                break
            }
        }

        while buffer.last == 0x0A || buffer.last == 0x0D {
            buffer.removeLast()
        }

        return buffer
    }

    static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesRemaining = rawBuffer.count
            var writeOffset = 0

            while bytesRemaining > 0 {
                let pointer = baseAddress.advanced(by: writeOffset)
                let bytesWritten = write(fileDescriptor, pointer, bytesRemaining)
                if bytesWritten < 0 {
                    let code = errno
                    if code == EINTR {
                        continue
                    }
                    throw POSIXError(.init(rawValue: code) ?? .EIO)
                }
                guard bytesWritten > 0 else {
                    throw POSIXError(.EIO)
                }

                bytesRemaining -= bytesWritten
                writeOffset += bytesWritten
            }
        }
    }

    static func configureNoSigPipe(for fileDescriptor: Int32) {
        #if canImport(Darwin)
        var value: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #else
        _ = fileDescriptor
        #endif
    }

    static func configureIOTimeouts(for fileDescriptor: Int32, seconds: Int = 30) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func makeSocketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < maxPathLength else {
            throw BurnBarDaemonError.socketPathTooLong(socketPath)
        }

        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        #endif

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        return address
    }
}
