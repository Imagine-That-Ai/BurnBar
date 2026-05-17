import Foundation
import os

/// FS-event watcher for Claude Code's statusline snapshot file. Fires the
/// supplied closure whenever the file changes so quota refresh latency drops
/// from "next 60-120 s auto-refresh tick" to "next debounce window" — the
/// difference between the Nest Hub showing 2-minute-old numbers and the
/// numbers Claude just wrote.
///
/// Self-heals across atomic writes. Some Claude bridge variants replace
/// `snapshot.json` via `mv tmp → snapshot`, which invalidates the FD. The
/// watcher cancels the source on `rename`/`delete` (the cancel handler
/// closes the captured FD) and re-arms with an exponential backoff that
/// stays cheap when the file does not yet exist (no Claude install) and
/// fast when we are racing an atomic write.
@MainActor
final class ClaudeStatuslineWatcher {

    /// Tuning knobs. Defaults match the existing routed-client wiring sentry
    /// so file-system handling is consistent across the codebase.
    struct Configuration {
        /// Window used to coalesce bursty writes. Claude's hook can emit
        /// several lines in quick succession during a streamed response;
        /// without this we'd kick a Claude refresh per line and hammer
        /// the adapter's JSONL scanner.
        var debounceNanoseconds: UInt64 = 250_000_000
        /// Initial reopen delay. Short — covers the brief gap between
        /// `unlink(old)` and `rename(new)` during an atomic write.
        var initialReopenBackoffNanoseconds: UInt64 = 250_000_000
        /// Cap on the exponential backoff. Long — when the file truly
        /// doesn't exist (Claude not installed) we don't want to syscall
        /// + log every 250 ms forever; settle into a quiet probe instead.
        var maxReopenBackoffNanoseconds: UInt64 = 30_000_000_000
        /// Multiplier applied to the backoff between failed reopens.
        var reopenBackoffMultiplier: Double = 2.0
        /// Mirrors RoutedClientWiringSentry — covers in-place writes,
        /// atomic replacements, permission rewrites, and link swaps.
        var monitoredEvents: DispatchSource.FileSystemEvent = [
            .write, .extend, .rename, .delete, .attrib, .link
        ]
    }

    private static let log = Logger(
        subsystem: "com.openburnbar.app",
        category: "ClaudeStatuslineWatcher"
    )

    private let url: URL
    private let configuration: Configuration
    private let queue: DispatchQueue
    private let onChange: @MainActor () -> Void

    /// Tracks whether a dispatch source is currently armed against the
    /// file. Never used as a value to `close()` — the captured `fd` local
    /// in the cancel handler owns the lifetime of the descriptor.
    private var isArmed: Bool = false
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var isStarted = false
    /// Current reopen backoff. Bumped by `reopenBackoffMultiplier` after
    /// each failed `arm()`, reset to `initialReopenBackoffNanoseconds`
    /// after a successful arm.
    private var currentReopenBackoff: UInt64
    /// Suppresses repeated "file missing" debug log lines while the
    /// backoff is still climbing — we only want one line per quiescent
    /// period, not one per probe.
    private var hasLoggedMissingFile: Bool = false

    init(
        url: URL,
        configuration: Configuration = Configuration(),
        queue: DispatchQueue = DispatchQueue(
            label: "com.openburnbar.claudeStatuslineWatcher",
            qos: .utility
        ),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.url = url
        self.configuration = configuration
        self.queue = queue
        self.onChange = onChange
        self.currentReopenBackoff = configuration.initialReopenBackoffNanoseconds
    }

    deinit {
        // Cancel cascades through the cancel handler which closes the FD.
        // Do NOT close the descriptor here — the source's cancel handler
        // owns the close. A redundant close races with FD reuse on
        // another thread (POSIX rule: never close an FD twice).
        source?.cancel()
    }

    /// Begin watching. Safe to call multiple times — a second `start()`
    /// is a no-op while the existing watch is live. If the file does not
    /// yet exist (bridge not installed), the watcher schedules a reopen
    /// with exponential backoff so a quiescent system pays one syscall
    /// every 30 s rather than four per second.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        currentReopenBackoff = configuration.initialReopenBackoffNanoseconds
        hasLoggedMissingFile = false
        arm()
    }

    func stop() {
        isStarted = false
        debounceTask?.cancel()
        debounceTask = nil
        reopenTask?.cancel()
        reopenTask = nil
        // Cancel cascades through the cancel handler which closes the FD.
        // See `deinit` for why we must not close anything ourselves.
        source?.cancel()
        source = nil
        isArmed = false
    }

    // MARK: - Internals

    private func arm() {
        guard isStarted else { return }
        guard source == nil else { return }

        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_EVTONLY)
        }
        guard fd >= 0 else {
            if !hasLoggedMissingFile {
                Self.log.debug(
                    "statusline file not present yet; backing off path=\(self.url.path, privacy: .public)"
                )
                hasLoggedMissingFile = true
            }
            scheduleReopen()
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: configuration.monitoredEvents,
            queue: queue
        )
        src.setEventHandler { [weak self] in
            let data = src.data
            Task { @MainActor [weak self] in
                self?.handleEvent(events: data)
            }
        }
        src.setCancelHandler {
            close(fd)
        }

        isArmed = true
        source = src
        // Successful arm — reset the backoff so the next rename/delete
        // recovers fast.
        currentReopenBackoff = configuration.initialReopenBackoffNanoseconds
        hasLoggedMissingFile = false
        src.resume()
        Self.log.debug("statusline watcher armed path=\(self.url.path, privacy: .public)")
    }

    private func handleEvent(events: DispatchSource.FileSystemEvent) {
        // When the file is rename-replaced, the old inode is gone — cancel
        // the source so the cancel handler can close the stale FD, then
        // re-arm against the new inode.
        if events.contains(.delete) || events.contains(.rename) {
            source?.cancel()
            source = nil
            isArmed = false
            scheduleReopen()
        }

        // Coalesce bursty writes so we don't fire the JSONL scanner per
        // streamed line during a single Claude turn.
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.configuration.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.onChange()
        }
    }

    private func scheduleReopen() {
        guard isStarted else { return }
        let delay = currentReopenBackoff
        // Bump for the next failed attempt; reset to initial on successful arm.
        let bumped = UInt64(Double(currentReopenBackoff) * configuration.reopenBackoffMultiplier)
        currentReopenBackoff = min(bumped, configuration.maxReopenBackoffNanoseconds)
        reopenTask?.cancel()
        reopenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, self.isStarted else { return }
            self.arm()
        }
    }
}
