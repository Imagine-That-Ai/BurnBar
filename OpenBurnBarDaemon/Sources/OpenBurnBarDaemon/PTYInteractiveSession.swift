import Darwin
import Foundation
import OpenBurnBarCore

// MARK: - PTYInteractiveSession

/// Errors thrown while managing an interactive PTY-backed subprocess.
public enum PTYInteractiveSessionError: Error, LocalizedError, Equatable {
    case ptyAllocationFailed(code: Int32)
    case executableNotFound(String)
    case spawnFailed(String)
    case sessionNotRunning
    case writeFailed(code: Int32)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .ptyAllocationFailed(let code):
            return "Failed to allocate a pseudo-terminal (errno \(code))."
        case .executableNotFound(let path):
            return "Interactive executable not found: \(path)."
        case .spawnFailed(let message):
            return "Failed to start interactive subprocess: \(message)."
        case .sessionNotRunning:
            return "Interactive PTY session is not running."
        case .writeFailed(let code):
            return "Failed to write to the PTY controller (errno \(code))."
        case .timedOut:
            return "Interactive PTY session timed out."
        }
    }
}

/// A subprocess attached to a pseudo-terminal (PTY) so it believes it is
/// running in a real interactive terminal.
///
/// This is the shared foundation for driving an interactive `claude` TUI
/// (launched **without** `-p`/`--print`, which is the explicitly-metered
/// programmatic path). A PTY-backed child behaves like a human-driven terminal
/// session: it renders its TUI, accepts keystrokes, and — critically for the
/// Part B premise — should draw against the subscription window rather than the
/// new Agent SDK credit pool.
///
/// ## Why a PTY (not pipes)
///
/// Interactive CLIs detect a TTY via `isatty(STDIN_FILENO)`. With plain
/// `Pipe`s the child sees a non-interactive stdin and either refuses to start
/// its TUI or silently switches to a batch mode. `openpty()` gives the child a
/// genuine controlling terminal while letting this process read/write the
/// controller side.
///
/// ## Concurrency
///
/// `@unchecked Sendable`: all mutable state is guarded by `Locked`. The output
/// read loop runs on a dedicated serial `DispatchQueue`; the caller-supplied
/// `onOutput` handler is invoked on that queue and must be `@Sendable`.
/// sendable-allowlist: process-handle
public final class PTYInteractiveSession: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var executableURL: URL
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: URL?
        public var columns: UInt16
        public var rows: UInt16

        public init(
            executableURL: URL,
            arguments: [String] = [],
            environment: [String: String] = [:],
            workingDirectory: URL? = nil,
            columns: UInt16 = 120,
            rows: UInt16 = 40
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.columns = columns
            self.rows = rows
        }
    }

    private struct State {
        var controllerFD: Int32 = -1
        var readSource: DispatchSourceRead?
        var transcript = Data()
        var lastOutputAt: Date?
        var isRunning = false
    }

    private let configuration: Configuration
    private let process = Process()
    private let state = Locked(State())
    private let readQueue = DispatchQueue(label: "com.openburnbar.pty-interactive-session.read")
    private let transcriptByteCap: Int

    public init(configuration: Configuration, transcriptByteCap: Int = 4 * 1024 * 1024) {
        self.configuration = configuration
        self.transcriptByteCap = max(64 * 1024, transcriptByteCap)
    }

    /// Whether the underlying subprocess is currently running.
    public var isRunning: Bool {
        state.read().isRunning && process.isRunning
    }

    /// Process identifier once started, else `nil`.
    public var processIdentifier: Int32? {
        state.read().isRunning ? process.processIdentifier : nil
    }

    // MARK: - Lifecycle

    /// Allocates a PTY, spawns the configured subprocess attached to its replica
    /// side, and begins relaying child output to `onOutput`.
    ///
    /// - Parameter onOutput: invoked on a dedicated serial queue for every
    ///   chunk the child writes. The same bytes are accumulated into the
    ///   capped in-memory transcript for `transcriptText()`.
    public func start(onOutput: @escaping @Sendable (Data) -> Void) throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw PTYInteractiveSessionError.executableNotFound(configuration.executableURL.path)
        }

        var controller: Int32 = -1
        var replica: Int32 = -1
        var window = winsize(
            ws_row: configuration.rows,
            ws_col: configuration.columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&controller, &replica, nil, nil, &window) == 0 else {
            throw PTYInteractiveSessionError.ptyAllocationFailed(code: errno)
        }

        // The child's controlling terminal is the replica; the parent keeps the
        // controller to read/write. `closeOnDealloc: false` because we own the
        // lifecycle explicitly and close the descriptor ourselves.
        let replicaHandle = FileHandle(fileDescriptor: replica, closeOnDealloc: false)

        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        var environment = configuration.environment
        if environment["TERM"] == nil {
            environment["TERM"] = "xterm-256color"
        }
        process.environment = environment
        if let workingDirectory = configuration.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        process.standardInput = replicaHandle
        process.standardOutput = replicaHandle
        process.standardError = replicaHandle

        process.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        let onOutputBox = onOutput
        let readSource = DispatchSource.makeReadSource(fileDescriptor: controller, queue: readQueue)
        let cap = transcriptByteCap
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                read(controller, ptr.baseAddress, 8192)
            }
            if bytesRead <= 0 {
                readSource.cancel()
                return
            }
            let chunk = Data(buffer.prefix(bytesRead))
            self.state.withLock { s in
                s.lastOutputAt = Date()
                s.transcript.append(chunk)
                if s.transcript.count > cap {
                    s.transcript.removeFirst(s.transcript.count - cap)
                }
            }
            onOutputBox(chunk)
        }
        readSource.setCancelHandler {
            close(controller)
        }

        do {
            try process.run()
        } catch {
            close(controller)
            close(replica)
            throw PTYInteractiveSessionError.spawnFailed(error.localizedDescription)
        }

        // Close the replica in the parent so the controller read sees EOF when the
        // child exits. The child retains its own duplicated descriptors.
        close(replica)

        state.withLock { s in
            s.controllerFD = controller
            s.readSource = readSource
            s.isRunning = true
            s.lastOutputAt = Date()
        }
        readSource.resume()
    }

    // MARK: - Input

    /// Writes raw text to the child's terminal input (no trailing newline).
    public func send(_ text: String) throws {
        try writeToController(Data(text.utf8))
    }

    /// Writes text followed by a carriage return — the keystroke an interactive
    /// TUI expects to submit a line (PTYs translate `\r` to `\n` via the line
    /// discipline).
    public func sendLine(_ text: String) throws {
        try writeToController(Data((text + "\r").utf8))
    }

    /// Sends a control character (e.g. `"c"` for Ctrl-C / `0x03`).
    public func sendControl(_ character: Character) throws {
        guard let ascii = character.uppercased().first?.asciiValue,
              ascii >= 64, ascii <= 95 || (ascii >= 96 && ascii <= 122) else {
            return
        }
        let controlByte = ascii & 0b0001_1111
        try writeToController(Data([controlByte]))
    }

    private func writeToController(_ data: Data) throws {
        let fd = state.read().controllerFD
        guard fd >= 0, isRunning else {
            throw PTYInteractiveSessionError.sessionNotRunning
        }
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress, remaining.count)
            }
            if written < 0 {
                throw PTYInteractiveSessionError.writeFailed(code: errno)
            }
            remaining.removeFirst(written)
        }
    }

    // MARK: - Observation

    /// The accumulated (capped) child output as UTF-8 text. Lossy decoding is
    /// used because TUI byte streams contain partial multi-byte sequences and
    /// ANSI control bytes.
    public func transcriptText() -> String {
        let data = state.read().transcript
        return String(decoding: data, as: UTF8.self)
    }

    /// The accumulated child output with ANSI escape sequences stripped, for
    /// scraping human-readable assistant text out of a TUI render.
    public func plainTranscriptText() -> String {
        PTYInteractiveSession.stripANSI(transcriptText())
    }

    /// Suspends until the child has produced no output for `idle` seconds, or
    /// `overall` seconds have elapsed since the call began. Returns `true` when
    /// quiescence was reached, `false` on the overall timeout.
    ///
    /// Used to detect "the assistant finished responding" without parsing the
    /// TUI's completion markers (which are undocumented and version-specific).
    public func waitForQuiescence(
        idle: TimeInterval = 2.5,
        overall: TimeInterval = 120
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(overall)
        while Date() < deadline {
            if !isRunning {
                return true
            }
            let lastOutput = state.read().lastOutputAt ?? Date()
            let quietFor = Date().timeIntervalSince(lastOutput)
            if quietFor >= idle {
                return true
            }
            let sleepFor = min(idle - quietFor, 0.25)
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, sleepFor) * 1_000_000_000))
        }
        return false
    }

    // MARK: - Termination

    /// Gracefully asks the child to exit (Ctrl-C twice for a TUI), then escalates
    /// to SIGTERM and SIGKILL. Closes the controller descriptor.
    public func terminate(graceful: TimeInterval = 1.5) {
        guard state.read().isRunning else { return }
        // Two interrupts is the common "cancel then quit" affordance for
        // interactive REPL/TUI clients.
        try? sendControl("c")
        try? sendControl("c")

        let deadline = Date().addingTimeInterval(graceful)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        handleTermination()
    }

    /// Blocks the calling task until the child exits (or `timeout` elapses).
    public func waitUntilExit(timeout: TimeInterval = 300) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The child's exit code once it has terminated, else `nil`.
    public var terminationStatus: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

    private func handleTermination() {
        let source: DispatchSourceRead? = state.withLock { s in
            guard s.isRunning else { return nil }
            s.isRunning = false
            let captured = s.readSource
            s.readSource = nil
            s.controllerFD = -1
            return captured
        }
        source?.cancel()
    }

    // MARK: - ANSI Stripping

    /// Removes ANSI/VT100 escape sequences and carriage-return artifacts so a
    /// scraped TUI transcript reads as plain text. Intentionally conservative —
    /// it strips CSI/OSC sequences and leaves printable content intact.
    public static func stripANSI(_ input: String) -> String {
        var output = String()
        output.reserveCapacity(input.count)
        var iterator = input.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()

        func advance() {
            pending = iterator.next()
        }

        while let scalar = pending {
            if scalar == "\u{1B}" { // ESC
                advance()
                guard let next = pending else { break }
                if next == "[" { // CSI — terminated by a byte in 0x40–0x7E
                    advance()
                    while let csi = pending {
                        if (0x40...0x7E).contains(csi.value) {
                            advance()
                            break
                        }
                        advance()
                    }
                    continue
                } else if next == "]" { // OSC — terminated by BEL or ESC \
                    advance()
                    while let osc = pending {
                        if osc == "\u{07}" {
                            advance()
                            break
                        }
                        if osc == "\u{1B}" {
                            advance()
                            if pending == "\\" { advance() }
                            break
                        }
                        advance()
                    }
                    continue
                } else {
                    // Two-byte escape (e.g. ESC c) — drop the intro byte.
                    advance()
                    continue
                }
            }
            if scalar == "\r" {
                advance()
                continue
            }
            output.unicodeScalars.append(scalar)
            advance()
        }
        return output
    }
}
