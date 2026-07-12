#if canImport(Glibc)
import Glibc
#endif
import Foundation
import OpenBurnBarCore

#if os(Linux)
extension BurnBarProjectCodeMemoryStore {
    // AUDIT(@unchecked Sendable): the inotify fd, watch maps, and dispatch source are
    // owned by the ProjectWatcher serial queue. Public interaction is cancel/drain on
    // that queue, and the fd is closed exactly once by the source cancel handler.
    // sendable-allowlist: serial-queue-confined-watcher
    final class LinuxFileSystemEventStream: @unchecked Sendable {
        private let fd: Int32
        private let source: DispatchSourceRead
        private let roots: [URL]
        private let onEvent: @Sendable () -> Void
        private let onRebuild: (@Sendable () -> Void)?
        private var watchDescriptorsByPath: [String: Int32] = [:]
        private var pathsByWatchDescriptor: [Int32: String] = [:]
        private static let eventBufferSize = 64 * 1_024
        private static let watchMask = UInt32(
            IN_ATTRIB
                | IN_CLOSE_WRITE
                | IN_CREATE
                | IN_DELETE
                | IN_DELETE_SELF
                | IN_MODIFY
                | IN_MOVE_SELF
                | IN_MOVED_FROM
                | IN_MOVED_TO
        )

        static func make(
            roots: [URL],
            queue: DispatchQueue,
            onEvent: @escaping @Sendable () -> Void,
            onRebuild: (@Sendable () -> Void)? = nil
        ) -> LinuxFileSystemEventStream? {
            let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
            guard fd >= 0 else { return nil }

            let stream = LinuxFileSystemEventStream(fd: fd, roots: roots, queue: queue, onEvent: onEvent, onRebuild: onRebuild)
            guard stream.installInitialWatches() else {
                stream.source.cancel()
                stream.source.resume()
                return nil
            }
            stream.source.setEventHandler { [weak stream] in
                guard let stream else { return }
                stream.drainEvents()
            }
            stream.source.resume()
            return stream
        }

        private init(
            fd: Int32,
            roots: [URL],
            queue: DispatchQueue,
            onEvent: @escaping @Sendable () -> Void,
            onRebuild: (@Sendable () -> Void)?
        ) {
            self.fd = fd
            self.roots = Self.uniqueCanonicalDirectories(roots)
            self.onEvent = onEvent
            self.onRebuild = onRebuild
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setCancelHandler {
                close(fd)
            }
        }

        func cancel() {
            source.cancel()
        }

        private func installInitialWatches() -> Bool {
            for root in roots {
                addDirectoryTree(root)
            }
            return watchDescriptorsByPath.isEmpty == false
        }

        private func rebuildWatches() {
            guard source.isCancelled == false else { return }
            onRebuild?()

            // Keep live watches installed. Removing them all queues IN_IGNORED
            // records whose descriptors can be reused by the replacement set,
            // causing the stale records to invalidate fresh watches repeatedly.
            let staleWatches = watchDescriptorsByPath.filter {
                Self.isDirectory(URL(fileURLWithPath: $0.key)) == false
            }
            for (path, wd) in staleWatches {
                watchDescriptorsByPath.removeValue(forKey: path)
                pathsByWatchDescriptor.removeValue(forKey: wd)
            }
            _ = installInitialWatches()
        }

        private func addDirectoryTree(_ root: URL) {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isDirectory(canonicalRoot), addWatch(canonicalRoot) else { return }
            guard let enumerator = FileManager.default.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for case let url as URL in enumerator {
                guard Self.isDirectory(url), Self.isSymbolicLink(url) == false else {
                    continue
                }
                let name = url.lastPathComponent
                if BurnBarProjectCodeMemoryStore.ignoredDirectories.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                _ = addWatch(url.resolvingSymlinksInPath().standardizedFileURL)
            }
        }

        @discardableResult
        private func addWatch(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            guard watchDescriptorsByPath[path] == nil else { return true }
            let wd = inotify_add_watch(fd, path, Self.watchMask)
            guard wd >= 0 else { return false }
            watchDescriptorsByPath[path] = wd
            pathsByWatchDescriptor[wd] = path
            return true
        }

        private func drainEvents() {
            var shouldNotify = false
            var shouldRebuild = false
            var buffer = [UInt8](repeating: 0, count: Self.eventBufferSize)

            while source.isCancelled == false {
                let bytesRead = Glibc.read(fd, &buffer, buffer.count)
                if bytesRead > 0 {
                    parseEvents(buffer: buffer, byteCount: bytesRead, shouldNotify: &shouldNotify, shouldRebuild: &shouldRebuild)
                    continue
                }
                if bytesRead == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                if bytesRead == -1 {
                    shouldRebuild = true
                }
                break
            }

            guard source.isCancelled == false else { return }
            if shouldRebuild {
                rebuildWatches()
            }
            if shouldNotify {
                onEvent()
            }
        }

        private func parseEvents(
            buffer: [UInt8],
            byteCount: Int,
            shouldNotify: inout Bool,
            shouldRebuild: inout Bool
        ) {
            let eventHeaderSize = MemoryLayout<inotify_event>.size
            var offset = 0
            buffer.withUnsafeBytes { rawBuffer in
                while offset + eventHeaderSize <= byteCount {
                    let event = rawBuffer.loadUnaligned(fromByteOffset: offset, as: inotify_event.self)
                    let eventLength = eventHeaderSize + Int(event.len)
                    guard eventLength > 0, offset + eventLength <= byteCount else { break }

                    handleEvent(
                        watchDescriptor: event.wd,
                        mask: event.mask,
                        name: Self.eventName(rawBuffer: rawBuffer, offset: offset + eventHeaderSize, length: Int(event.len)),
                        shouldNotify: &shouldNotify,
                        shouldRebuild: &shouldRebuild
                    )
                    offset += eventLength
                }
            }
        }

        private func handleEvent(
            watchDescriptor: Int32,
            mask: UInt32,
            name: String?,
            shouldNotify: inout Bool,
            shouldRebuild: inout Bool
        ) {
            shouldNotify = true

            if mask & UInt32(IN_Q_OVERFLOW) != 0 {
                shouldRebuild = true
                return
            }

            if mask & UInt32(IN_IGNORED) != 0 {
                if let path = pathsByWatchDescriptor.removeValue(forKey: watchDescriptor) {
                    watchDescriptorsByPath.removeValue(forKey: path)
                    shouldRebuild = true
                }
                return
            }

            if mask & UInt32(IN_DELETE_SELF | IN_MOVE_SELF) != 0 {
                shouldRebuild = true
            }

            let createdDirectoryMask = UInt32(IN_CREATE | IN_MOVED_TO)
            if mask & createdDirectoryMask != 0,
               mask & UInt32(IN_ISDIR) != 0,
               let parent = pathsByWatchDescriptor[watchDescriptor],
               let name,
               name.isEmpty == false {
                let child = URL(fileURLWithPath: parent, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
                addDirectoryTree(child)
            }
        }

        private static func eventName(rawBuffer: UnsafeRawBufferPointer, offset: Int, length: Int) -> String? {
            guard length > 0 else { return nil }
            let end = offset + length
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            var index = offset
            while index < end {
                let byte = rawBuffer.load(fromByteOffset: index, as: UInt8.self)
                if byte == 0 { break }
                bytes.append(byte)
                index += 1
            }
            guard bytes.isEmpty == false else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }

        private static func uniqueCanonicalDirectories(_ urls: [URL]) -> [URL] {
            var seen = Set<String>()
            var result: [URL] = []
            for url in urls {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard isDirectory(canonical), seen.insert(canonical.path).inserted else { continue }
                result.append(canonical)
            }
            return result
        }

        private static func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }

        private static func isSymbolicLink(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        }

#if DEBUG
        func simulateQueueOverflowForTesting() {
            var shouldNotify = false
            var shouldRebuild = false
            handleEvent(
                watchDescriptor: -1,
                mask: UInt32(IN_Q_OVERFLOW),
                name: nil,
                shouldNotify: &shouldNotify,
                shouldRebuild: &shouldRebuild
            )
            if shouldRebuild {
                rebuildWatches()
            }
            if shouldNotify {
                onEvent()
            }
        }
#endif
    }

#if DEBUG
    static func _testOnlyMakeLinuxFileSystemEventStream(
        roots: [URL],
        queue: DispatchQueue,
        onEvent: @escaping @Sendable () -> Void,
        onRebuild: (@Sendable () -> Void)? = nil
    ) -> AnyObject? {
        LinuxFileSystemEventStream.make(roots: roots, queue: queue, onEvent: onEvent, onRebuild: onRebuild)
    }

    static func _testOnlyCancelLinuxFileSystemEventStream(_ stream: AnyObject) {
        (stream as? LinuxFileSystemEventStream)?.cancel()
    }

    static func _testOnlySimulateLinuxInotifyQueueOverflow(_ stream: AnyObject, queue: DispatchQueue) {
        queue.sync {
            (stream as? LinuxFileSystemEventStream)?.simulateQueueOverflowForTesting()
        }
    }
#endif
}
#endif
