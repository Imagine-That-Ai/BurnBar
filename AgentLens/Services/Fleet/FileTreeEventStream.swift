import Foundation

#if canImport(CoreServices)
import CoreServices
#endif

// MARK: - File tree event stream
//
// A recursive FSEvents watcher over one directory tree, delivering the changed
// paths on a caller-supplied queue.
//
// Lifted from `BurnBarProjectCodeMemoryStore.makeFileSystemEventStream` — the
// retained-`info` context, the balanced release callback, and the
// invalidate-then-release teardown ordering are that implementation's, and are
// the parts that are easy to get subtly wrong.
//
// Two deliberate differences from the daemon's version, both because this feeds
// a UI panel rather than a reindexer:
//
//   * **Latency 1.0s, not 0.2s.** A fleet panel does not need 200ms, and
//     kernel-side coalescing is the single biggest battery lever available
//     here.
//   * **No `kFSEventStreamCreateFlagNoDefer`.** `NoDefer` delivers the *first*
//     event of a burst immediately, which is right for a reindexer that wants
//     to start early and wrong for a panel that only needs the end state. With
//     it off we get one wakeup at the end of the window and the panel's answer
//     is identical.
//
// `kFSEventStreamCreateFlagFileEvents` stays on: it gives per-file paths, which
// is what lets a row name the project it saw activity in.
//
// Why FSEvents and not `DispatchSource.makeFileSystemObjectSource`: the latter
// needs one file descriptor per node and does not recurse. `~/.claude/projects`
// is one directory per project and can be hundreds of directories holding
// thousands of `.jsonl` files. One FSEvents stream covers the whole tree.
// Single fixed files (Claude's statusline snapshot) correctly stay on
// `DispatchSource` — see `ClaudeStatuslineWatcher`.

final class FileTreeEventStream {

    /// Delivered with the changed paths, coalesced by the kernel.
    typealias Handler = @Sendable ([String]) -> Void

    private let root: URL
    private let queue: DispatchQueue
    private let latency: CFTimeInterval
    private let handler: Handler

#if canImport(CoreServices)
    private var stream: FSEventStreamRef?
#endif

    /// - Parameters:
    ///   - latency: coalescing window handed to FSEvents. Injectable so tests
    ///     can drop it without every other caller paying for a hot stream.
    init(
        root: URL,
        queue: DispatchQueue,
        latency: CFTimeInterval = 1.0,
        handler: @escaping Handler
    ) {
        self.root = root
        self.queue = queue
        self.latency = latency
        self.handler = handler
    }

    deinit { stopStream() }

    /// Arms the watcher. Returns false when the stream could not be created —
    /// callers must surface that as `unobservable` rather than silently
    /// rendering an agent as quiet.
    @discardableResult
    func start() -> Bool {
#if canImport(CoreServices)
        guard stream == nil else { return true }
        guard FileManager.default.fileExists(atPath: root.path) else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { pointer in
                if let pointer { Unmanaged<FileTreeEventStream>.fromOpaque(pointer).release() }
            },
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileTreeEventCallback,
            &context,
            [root.path] as CFArray,
            // Since-now: on a re-arm after wake we deliberately do NOT replay
            // history. Events from while the machine slept are not evidence of
            // current activity, and replaying them would repopulate exactly the
            // stale timestamps the sleep gap exists to suppress.
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            // Balance the retain we passed in, or the stream leaks `self`.
            if let info = context.info {
                Unmanaged<FileTreeEventStream>.fromOpaque(info).release()
            }
            return false
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        return true
#else
        return false
#endif
    }

    /// Tears the watcher down. Safe to call repeatedly.
    ///
    /// Called on display sleep, not just on deinit: a stream that survives
    /// sleep wakes the process on every write from a CLI running with the lid
    /// closed, which is strictly worse than the 60s poll it replaced.
    func stop() { stopStream() }

    private func stopStream() {
#if canImport(CoreServices)
        guard let stream else { return }
        self.stream = nil
        // Order matters: stop, then invalidate, then release. Releasing first
        // frees the context (and with it `self`) while the stream may still be
        // scheduled to fire.
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
#endif
    }

    fileprivate func deliver(paths: [String]) {
        guard paths.isEmpty == false else { return }
        handler(paths)
    }
}

#if canImport(CoreServices)
private func fileTreeEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, count > 0 else { return }
    let watcher = Unmanaged<FileTreeEventStream>.fromOpaque(info).takeUnretainedValue()
    guard let cfPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    watcher.deliver(paths: cfPaths)
}
#endif
