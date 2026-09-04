#if canImport(CoreServices)
import CoreServices
#endif
import Foundation
import OpenBurnBarEngine

// Live project watching: per-project watcher state, native filesystem event
// streams (FSEvents / inotify) with a polling backstop, and snapshot-time
// suspend / resume.
extension BurnBarProjectCodeMemoryStore {
    // AUDIT(@unchecked Sendable): DispatchSourceTimer callback owns mutable watcher state on its serial queue.
    // sendable-allowlist: foundation-sdk-shim
    final class ProjectWatcher: @unchecked Sendable {
        let projectID: String
        let projectRoot: URL
        let maxFiles: Int
        let maxFileBytes: Int
        let storageBudgetBytes: Int
        let timer: DispatchSourceTimer
        let pollIntervalSeconds: TimeInterval
#if canImport(CoreServices)
        var fseventStream: FSEventStreamRef?
#endif
#if os(Linux)
        var linuxEventStream: LinuxFileSystemEventStream?
#endif
        var lastSignature: String
        /// Event-driven change source (sub-second responsiveness). The timer above is
        /// the reliability backstop for volumes/conditions where native events can miss.
#if canImport(CoreServices)
        var eventStream: FSEventStreamRef?
#endif
        var onFileSystemEvent: (() -> Void)?

        init(
            projectID: String,
            projectRoot: URL,
            maxFiles: Int,
            maxFileBytes: Int,
            storageBudgetBytes: Int,
            timer: DispatchSourceTimer,
            pollIntervalSeconds: TimeInterval,
            lastSignature: String
        ) {
            self.projectID = projectID
            self.projectRoot = projectRoot
            self.maxFiles = maxFiles
            self.maxFileBytes = maxFileBytes
            self.storageBudgetBytes = storageBudgetBytes
            self.timer = timer
            self.pollIntervalSeconds = pollIntervalSeconds
            self.lastSignature = lastSignature
        }

        func nudge() {
            timer.schedule(deadline: .now() + 0.05, repeating: pollIntervalSeconds)
        }

        deinit {
#if canImport(CoreServices)
            if let fseventStream {
                FSEventStreamStop(fseventStream)
                FSEventStreamInvalidate(fseventStream)
                FSEventStreamRelease(fseventStream)
            }
#endif
            timer.cancel()
            teardownEventStream()
        }

        /// Stop native filesystem event delivery. Idempotent. On macOS the FSEvents
        /// stream was created with a retained `info` (+1 on this watcher), so releasing
        /// it balances that reference; invalidation guarantees no further callbacks fire
        /// afterward, so there is no use-after-free on teardown. On Linux, canceling the
        /// dispatch read source closes the inotify fd in its cancel handler.
        func teardownEventStream() {
#if canImport(CoreServices)
            guard let stream = eventStream else { return }
            eventStream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
#endif
#if os(Linux)
            linuxEventStream?.cancel()
            linuxEventStream = nil
#endif
        }
    }

    func watchProject(_ request: BurnBarProjectCodeWatchProjectRequest) throws -> BurnBarProjectCodeWatchProjectResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try resolveProjectIdentity(root: root).projectID
        let maxFiles = max(1, min(request.maxFiles, 25_000))
        let maxFileBytes = max(1_024, min(request.maxFileBytes, 10_000_000))
        let storageBudgetBytes = Self.normalizedStorageBudgetBytes(request.storageBudgetBytes)
        let interval = max(0.25, min(request.pollIntervalSeconds, 300.0))

        let indexed = try indexProject(
            BurnBarProjectCodeIndexProjectRequest(
                projectPath: root.path,
                maxFiles: maxFiles,
                maxFileBytes: maxFileBytes,
                storageBudgetBytes: storageBudgetBytes
            )
        )
        let signature = Self.projectIndexSignature(root: root, maxFiles: maxFiles)

        let queue = DispatchQueue(label: "com.openburnbar.daemon.project-code-memory.watch.\(projectID)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let watcher = ProjectWatcher(
            projectID: projectID,
            projectRoot: root,
            maxFiles: maxFiles,
            maxFileBytes: maxFileBytes,
            storageBudgetBytes: storageBudgetBytes,
            timer: timer,
            pollIntervalSeconds: interval,
            lastSignature: signature
        )
        // Backstop poll: reliably catches anything FSEvents coalesces or misses.
        timer.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.reindexWatcherIfChanged(watcher)
        }
        timer.schedule(deadline: .now() + interval, repeating: interval)

        // Event-driven fast path: native filesystem events fire on real changes
        // under the project root — including .git/HEAD and refs on branch switches — so a
        // change is reindexed in sub-second time instead of waiting a full poll interval.
        watcher.onFileSystemEvent = { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.reindexWatcherIfChanged(watcher)
        }
#if canImport(CoreServices)
        watcher.eventStream = Self.makeFileSystemEventStream(root: root, queue: queue, watcher: watcher)
#endif
#if os(Linux)
        watcher.linuxEventStream = LinuxFileSystemEventStream.make(
            roots: Self.projectWatchEventPaths(root: root),
            queue: queue,
            onEvent: { [weak watcher] in
                watcher?.onFileSystemEvent?()
            }
        )
#endif

        databaseSync {
            if let previous = projectWatchers[projectID] {
                previous.timer.cancel()
                previous.teardownEventStream()
            }
            projectWatchers[projectID] = watcher
        }
        timer.resume()

        return BurnBarProjectCodeWatchProjectResponse(
            traceID: traceID,
            projectID: projectID,
            projectRoot: root.path,
            watching: true,
            pollIntervalSeconds: interval,
            signature: signature,
            indexedFiles: indexed.indexedFiles
        )
    }

    /// Re-walk the project signature and full-reindex only when it changed. Invoked by
    /// both the FSEvents fast path and the poll backstop; both run on the same serial
    /// watch queue so reindexes never overlap.
    private func reindexWatcherIfChanged(_ watcher: ProjectWatcher) {
        let currentSignature = Self.projectIndexSignature(root: watcher.projectRoot, maxFiles: watcher.maxFiles)
        guard currentSignature != watcher.lastSignature else { return }
        do {
            _ = try indexProject(
                BurnBarProjectCodeIndexProjectRequest(
                    projectPath: watcher.projectRoot.path,
                    maxFiles: watcher.maxFiles,
                    maxFileBytes: watcher.maxFileBytes,
                    storageBudgetBytes: watcher.storageBudgetBytes
                )
            )
            watcher.lastSignature = currentSignature
            logger.notice(
                "project_code_memory_watch_reindexed",
                metadata: ["project_id": watcher.projectID, "signature": currentSignature]
            )
        } catch {
            logger.warning(
                "project_code_memory_watch_reindex_failed",
                metadata: ["project_id": watcher.projectID, "error": error.localizedDescription]
            )
        }
    }

#if canImport(CoreServices)
    /// FSEvents C callback bridges back to the watcher through the retained `info`.
    private static let fileSystemEventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue().onFileSystemEvent?()
    }

    /// Create + start a recursive FSEvents stream over `root`, delivering on `queue`.
    /// The watcher is retained for the stream's lifetime (balanced by the context
    /// release callback, which teardownEventStream triggers via FSEventStreamRelease),
    /// so the callback can never dereference a freed pointer. Returns nil if the stream
    /// cannot be created — the poll backstop still guarantees eventual reindex.
    private static func makeFileSystemEventStream(root: URL, queue: DispatchQueue, watcher: ProjectWatcher) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(watcher).toOpaque(),
            retain: nil,
            release: { pointer in
                if let pointer { Unmanaged<ProjectWatcher>.fromOpaque(pointer).release() }
            },
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileSystemEventCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            if let info = context.info {
                Unmanaged<ProjectWatcher>.fromOpaque(info).release()
            }
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return stream
    }
#endif

    func suspendProjectWatchersForSnapshot() -> [BurnBarProjectCodeWatchProjectRequest] {
        let requests = projectWatchers.values.map { watcher in
            BurnBarProjectCodeWatchProjectRequest(
                projectPath: watcher.projectRoot.path,
                maxFiles: watcher.maxFiles,
                maxFileBytes: watcher.maxFileBytes,
                storageBudgetBytes: watcher.storageBudgetBytes,
                pollIntervalSeconds: watcher.pollIntervalSeconds
            )
        }
        for watcher in projectWatchers.values {
            watcher.timer.cancel()
            watcher.teardownEventStream()
        }
        projectWatchers.removeAll()
        return requests
    }

    func resumeProjectWatchersAfterSnapshot(_ requests: [BurnBarProjectCodeWatchProjectRequest]) throws {
        for request in requests {
            _ = try watchProject(request)
        }
    }
}
