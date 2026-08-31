import Foundation

// MARK: - CLI Terminal Session Supervisor (Foundation-pure stream supervision)
//
// Core-decomposition P-18 (docs/CORE_DECOMPOSITION_PROGRAM.md): the pure,
// Foundation-only supervised-CLI stream/quota-classification surface, extracted
// DOWN from `OpenBurnBarLaunchServices/CLITerminalSessionSupervisor.swift` into the
// cross-platform Kernel so the daemon repoint reaches it WITHOUT linking the
// AppKit-adjacent, Apple-only `OpenBurnBarLaunchServices` target (Engine — the
// UI-free umbrella the daemon links — re-exports Kernel but NOT LaunchServices).
// The daemon's supervised-CLI shell (`OpenBurnBarSwitcherShell`) constructs a
// `CLITerminalSessionSupervisor` and calls `CLIQuotaExhaustionClassifier.classify`;
// AgentLens' CLIBridge uses the same types. Pure code motion, zero behavior change.
// `SwitcherCLIProfileType` / `Locked` resolve in-module now (both Kernel), so the
// former `import OpenBurnBarKernel` (a self-import inside the Kernel target) is
// dropped.
//
// This file was ungated inside the whole-off-Apple-pruned LaunchServices target, so
// it compiled on every Apple platform (macOS + iOS) and never off-Apple. The
// `#if canImport(Darwin)` guard preserves that exact surface now that it lives in
// the cross-platform Kernel (which also builds on Linux/Windows): the types stay
// present on Apple and absent off-Apple, byte-identical to the pre-move build.
#if canImport(Darwin)

public enum CLITerminalSessionOutputSource: String, Equatable, Sendable {
    case stdout
    case stderr
}

public enum CLITerminalSessionEvent: Equatable, Sendable {
    case quotaExhausted(detail: String, source: CLITerminalSessionOutputSource)
}

public enum CLIQuotaExhaustionClassifier {
    public static func exhaustionWindowEnd(from detail: String, now: Date) -> Date? {
        let normalized = detail.lowercased()
        if normalized.contains("weekly") || normalized.contains("week") {
            return now.addingTimeInterval(7 * 24 * 60 * 60)
        }
        if normalized.contains("monthly")
            || normalized.contains("month")
            || normalized.contains("credit limit") {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month], from: now)
            if let monthStart = calendar.date(from: components),
               let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) {
                return nextMonth
            }
            return now.addingTimeInterval(30 * 24 * 60 * 60)
        }
        if normalized.contains("5-hour")
            || normalized.contains("5 hour")
            || normalized.contains("5h")
            || normalized.contains("hour window")
            || normalized.contains("usage limit")
            || normalized.contains("out of limit")
            || normalized.contains("you've reached your limit")
            || normalized.contains("you have reached your limit") {
            return now.addingTimeInterval(5 * 60 * 60)
        }
        return nil
    }

    public static func classify(
        for cliType: SwitcherCLIProfileType,
        in output: String
    ) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let genericPatterns = [
            "quota exhausted",
            "quota exceeded",
            "usage limit reached",
            "exceeded your current quota",
            "insufficient_quota",
            "insufficient quota",
            "credit balance is too low",
            "billing quota exceeded"
        ]

        let weakLimitPatterns = [
            "out of limit",
            "out of limits"
        ]

        let weakLimitAnchors = [
            "quota",
            "rate limit",
            "rate-limit",
            "usage limit",
            "credit",
            "billing",
            "plan limit"
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
            "monthly limit reached",
            "monthly credit limit reached",
            "5 hour limit reached"
        ]

        let cliSpecificPatterns: [String]
        switch cliType {
        case .codex:
            cliSpecificPatterns = [
                "codex quota",
                "codex is out of limit",
                "codex is out of limits",
                "chatgpt plan limit",
                "run codex and use /status to refresh local quota data"
            ]
        case .claude:
            cliSpecificPatterns = [
                "claude code usage limit",
                "anthropic quota",
                "rate-limit payload"
            ]
        case .opencode:
            cliSpecificPatterns = [
                "opencode quota",
                "opencode go quota",
                "opencode credit"
            ]
        case .droid:
            cliSpecificPatterns = [
                "droid quota",
                "factory quota",
                "factory usage limit"
            ]
        case .forge:
            cliSpecificPatterns = [
                "forge quota",
                "forge credit",
                "provider quota"
            ]
        case .antigravity:
            cliSpecificPatterns = [
                "antigravity quota",
                "agy quota",
                "gemini quota",
                "google ai quota"
            ]
        case .grok:
            cliSpecificPatterns = [
                "grok quota",
                "xai quota",
                "supergrok limit",
                "grok build limit"
            ]
        case .cursorAgent:
            cliSpecificPatterns = [
                "cursor quota",
                "cursor limit",
                "cursor-agent quota",
                "cursor-agent limit",
                "cursor agent quota",
                "cursor agent limit"
            ]
        case .omp:
            cliSpecificPatterns = [
                "omp quota",
                "oh my pi quota",
                "omp usage limit",
                "provider quota"
            ]
        case .gemini:
            cliSpecificPatterns = [
                "gemini quota",
                "google ai quota",
                "approval-mode",
                "yolo mode"
            ]
        case .kimi:
            cliSpecificPatterns = [
                "kimi quota",
                "moonshot quota",
                "kimi limit"
            ]
        case .pi:
            cliSpecificPatterns = [
                "pi quota",
                "pi limit",
                "provider quota"
            ]
        case .junie:
            cliSpecificPatterns = [
                "junie quota",
                "junie limit",
                "jetbrains ai quota",
                "remaining balance"
            ]
        case .primeAgent:
            cliSpecificPatterns = [
                "prime quota",
                "prime-agent quota",
                "prime agent quota",
                "prime limit"
            ]
        case .fx:
            cliSpecificPatterns = [
                "fx quota",
                "fx limit",
                "vercel quota",
                "vercel fx quota"
            ]
        case .hermes:
            cliSpecificPatterns = [
                "hermes quota",
                "hermes limit",
                "hermes session limit"
            ]
        case .goose:
            cliSpecificPatterns = [
                "goose quota",
                "goose limit",
                "block goose quota"
            ]
        case .windsurf:
            cliSpecificPatterns = [
                "windsurf quota",
                "windsurf limit",
                "codeium quota",
                "flex credit"
            ]
        case .openClaude:
            cliSpecificPatterns = [
                "openclaude quota",
                "claude code usage limit",
                "anthropic quota"
            ]
        case .openClaw:
            cliSpecificPatterns = [
                "openclaw quota",
                "openclaw limit"
            ]
        }

        let candidates = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(64)
        for candidate in candidates {
            let normalized = candidate.lowercased()

            if genericPatterns.contains(where: normalized.contains) {
                return candidate
            }
            if rateLimitPatterns.contains(where: normalized.contains) {
                return candidate
            }
            if weakLimitPatterns.contains(where: normalized.contains) {
                let anchoredToQuotaSource = weakLimitAnchors.contains(where: normalized.contains)
                    || cliSpecificPatterns.contains(where: normalized.contains)
                if anchoredToQuotaSource {
                    return candidate
                }
            }
            if normalized.contains("too many requests")
                && (normalized.contains("quota") || normalized.contains("rate limit") || normalized.contains("limit reached")) {
                return candidate
            }
            if cliSpecificPatterns.contains(where: normalized.contains)
                && (normalized.contains("limit reached")
                    || normalized.contains("limit exceeded")
                    || normalized.contains("quota exhausted")
                    || normalized.contains("quota exceeded")
                    || normalized.contains("exhaust")) {
                return candidate
            }
        }

        return nil
    }
}

public final class CLITerminalSessionSupervisor: Sendable {
    public typealias EventHandler = @Sendable (CLITerminalSessionEvent) -> Void

    private let cliType: SwitcherCLIProfileType
    private let eventHandler: EventHandler
    private struct State {
        var chunks: [String] = []
        var didEmitQuotaEvent = false
    }
    private let state = Locked(State())

    public init(
        cliType: SwitcherCLIProfileType,
        eventHandler: @escaping EventHandler
    ) {
        self.cliType = cliType
        self.eventHandler = eventHandler
    }

    public func ingest(_ text: String, source: CLITerminalSessionOutputSource) {
        guard !text.isEmpty else { return }

        let matchedDetail: String? = state.withLock { s in
            s.chunks.append(text)
            if s.chunks.count > 256 {
                s.chunks.removeFirst(s.chunks.count - 256)
            }

            guard !s.didEmitQuotaEvent else { return nil }
            guard let detail = CLIQuotaExhaustionClassifier.classify(for: cliType, in: s.chunks.joined()) else {
                return nil
            }

            s.didEmitQuotaEvent = true
            return detail
        }

        guard let matchedDetail else { return }
        eventHandler(.quotaExhausted(detail: matchedDetail, source: source))
    }

    public func snapshot() -> String {
        state.withLock { $0.chunks.joined() }
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
            let sourceReadableBytes = readSource.data
            let readableBytes = sourceReadableBytes > UInt(Int.max)
                ? Int.max
                : Int(sourceReadableBytes)
            var remainingBytes = max(readableBytes, bufferSize)

            while remainingBytes > 0 {
                let requestedBytes = min(bufferSize, remainingBytes)
                // Use read() system call - returns -1 on error (pipe closed), 0 on EOF, >0 on data.
                // This avoids NSFileHandleOperationException from availableData when pipe is closed.
                let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                    read(fd, ptr.baseAddress, requestedBytes)
                }

                if bytesRead <= 0 {
                    // Pipe closed or error - stop reading
                    readSource.cancel()
                    return
                }

                if let text = String(bytes: buffer.prefix(bytesRead), encoding: .utf8),
                   !text.isEmpty {
                    self.ingest(text, source: source)
                }

                remainingBytes -= bytesRead
                if bytesRead < requestedBytes {
                    break
                }
            }
        }
        readSource.resume()

        return CLITerminalSessionPipeObserver {
            readSource.cancel()
            try? pipe.fileHandleForReading.close()
        }
    }
}

public final class CLITerminalSessionPipeObserver: Sendable {
    private let didCancel = Locked(false)
    private let cancelAction: @Sendable () -> Void

    init(cancelAction: @escaping @Sendable () -> Void) {
        self.cancelAction = cancelAction
    }

    public func cancel() {
        let shouldCancel = didCancel.withLock { flag -> Bool in
            guard !flag else { return false }
            flag = true
            return true
        }

        guard shouldCancel else { return }
        cancelAction()
    }
}

#endif
