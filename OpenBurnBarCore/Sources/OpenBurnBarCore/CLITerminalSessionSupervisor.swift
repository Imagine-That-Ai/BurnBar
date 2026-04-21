import Foundation

public enum CLITerminalSessionOutputSource: String, Equatable, Sendable {
    case stdout
    case stderr
}

public enum CLITerminalSessionEvent: Equatable, Sendable {
    case quotaExhausted(detail: String, source: CLITerminalSessionOutputSource)
}

public enum CLIQuotaExhaustionClassifier {
    public static func classify(
        for cliType: SwitcherCLIProfileType,
        in output: String
    ) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased()
        let genericPatterns = [
            "quota exhausted",
            "quota exceeded",
            "usage limit reached",
            "exceeded your current quota",
            "insufficient_quota",
            "insufficient quota",
            "credit balance is too low",
            "billing quota exceeded",
        ]

        let rateLimitPatterns = [
            "rate limit exceeded",
            "rate-limit exceeded",
            "rate limit reached",
            "rate-limit reached",
            "you've reached your limit",
            "you have reached your limit",
            "5-hour limit reached",
            "weekly limit reached",
            "5 hour limit reached",
        ]

        let cliSpecificPatterns: [String]
        switch cliType {
        case .codex:
            cliSpecificPatterns = [
                "codex quota",
                "chatgpt plan limit",
                "run codex and use /status to refresh local quota data",
            ]
        case .claude:
            cliSpecificPatterns = [
                "claude code usage limit",
                "anthropic quota",
                "rate-limit payload",
            ]
        case .opencode:
            cliSpecificPatterns = [
                "opencode quota",
            ]
        }

        if genericPatterns.contains(where: normalized.contains) {
            return trimmed
        }
        if rateLimitPatterns.contains(where: normalized.contains) {
            return trimmed
        }
        if normalized.contains("too many requests")
            && (normalized.contains("quota") || normalized.contains("rate limit") || normalized.contains("limit reached")) {
            return trimmed
        }
        if cliSpecificPatterns.contains(where: normalized.contains)
            && (normalized.contains("limit") || normalized.contains("quota") || normalized.contains("exhaust")) {
            return trimmed
        }

        return nil
    }
}

public final class CLITerminalSessionSupervisor: @unchecked Sendable {
    public typealias EventHandler = @Sendable (CLITerminalSessionEvent) -> Void

    private let cliType: SwitcherCLIProfileType
    private let eventHandler: EventHandler
    private let lock = NSLock()
    private var chunks: [String] = []
    private var didEmitQuotaEvent = false

    public init(
        cliType: SwitcherCLIProfileType,
        eventHandler: @escaping EventHandler
    ) {
        self.cliType = cliType
        self.eventHandler = eventHandler
    }

    public func ingest(_ text: String, source: CLITerminalSessionOutputSource) {
        guard !text.isEmpty else { return }

        let matchedDetail: String? = lock.withLock {
            chunks.append(text)
            if chunks.count > 256 {
                chunks.removeFirst(chunks.count - 256)
            }

            guard !didEmitQuotaEvent else { return nil }
            guard let detail = CLIQuotaExhaustionClassifier.classify(for: cliType, in: chunks.joined()) else {
                return nil
            }

            didEmitQuotaEvent = true
            return detail
        }

        guard let matchedDetail else { return }
        eventHandler(.quotaExhausted(detail: matchedDetail, source: source))
    }

    public func snapshot() -> String {
        lock.withLock { chunks.joined() }
    }

    public func attach(
        to pipe: Pipe,
        source: CLITerminalSessionOutputSource,
        queue: DispatchQueue
    ) -> CLITerminalSessionPipeObserver {
        let fd = pipe.fileHandleForReading.fileDescriptor
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: queue
        )
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            // Use read() system call - returns -1 on error (pipe closed), 0 on EOF, >0 on data.
            // This avoids NSFileHandleOperationException from availableData when pipe is closed.
            let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, bufferSize)
            }
            
            if bytesRead <= 0 {
                // Pipe closed or error - stop reading
                readSource.cancel()
                return
            }
            
            guard let text = String(bytes: buffer.prefix(bytesRead), encoding: .utf8),
                  !text.isEmpty else {
                return
            }
            self.ingest(text, source: source)
        }
        readSource.resume()

        return CLITerminalSessionPipeObserver {
            readSource.cancel()
            try? pipe.fileHandleForReading.close()
        }
    }
}

public final class CLITerminalSessionPipeObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var didCancel = false
    private let cancelAction: () -> Void

    init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    public func cancel() {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !didCancel else { return false }
            didCancel = true
            return true
        }

        guard shouldCancel else { return }
        cancelAction()
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
