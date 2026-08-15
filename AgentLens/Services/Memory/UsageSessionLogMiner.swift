import Foundation
import OpenBurnBarCore

// MARK: - Usage Session Log Miner (PR4)

/// Stage-0 miner over recorded agent-session rollouts (`~/.codex/sessions`).
///
/// Each `mineTick` incrementally walks `rollout-*.jsonl` files, replays user
/// turns and repeated tool patterns through `UsageMemoryCandidateGate`, and
/// spools accepted candidates into `memory_usage_candidates` together with a
/// per-file byte cursor — candidates and cursor commit in ONE transaction, so
/// a crash can never persist a cursor past unpersisted candidates.
///
/// Incident disciplines honored (2026-07-16 parser blowup):
///  * every decoded line drains inside `parserAutoReleasePool`;
///  * reads ride `BufferedLineReader` under a `ParserResourceGovernor`
///    (32 MiB/tick byte budget, 2 GiB memory ceiling) plus a ≤25-file and
///    20 s wall-clock cap per tick — deferred files retry next tick;
///  * the codex SQLite index (`state_5.sqlite`) is never opened: the miner
///    enumerates rollout files directly, so no read snapshot can ever be
///    pinned across file I/O;
///  * the cursor is the miner's own (`usage_memory.session_miner.cursor.v1`)
///    — it never touches `codex_parser_cache.json` or the usage-aggregation
///    scan states.
///
/// Cursor semantics mirror `CodexTokenScanState`: `byteOffset` always points
/// just past the last *terminated* line consumed (a live writer may be
/// mid-append on the tail line, so unterminated tails are never covered), and
/// a FNV-1a 64 digest of the file head detects rewrites, which restart the
/// file from offset 0 (content-derived candidate ids make the replay
/// idempotent). `lastMtime` records the file's modification time at the end
/// of a fully-consumed scan so unchanged files are skipped on stat alone.
actor UsageSessionLogMiner {

    /// Per-file resume state, JSON-encoded as `[path: cursor]` into the
    /// `controller_runtime_cache` row named by
    /// `ControlPlaneStore.usageSessionMinerCursorKey`.
    struct MinerFileCursor: Codable, Equatable, Sendable {
        var byteOffset: Int64
        /// FNV-1a 64 over the file's first `headDigestLength` bytes when the
        /// cursor was created; a mismatch means rewrite ⇒ restart at 0.
        var headDigest: UInt64
        var headDigestLength: Int
        /// Modification time (seconds since 1970) when the cursor last
        /// covered the whole file. A file whose mtime and size are both
        /// unchanged is skipped without being opened.
        var lastMtime: Double?
    }

    struct TickReport: Equatable, Sendable {
        var filesRead = 0
        var filesDeferred = 0
        var bytesRead: Int64 = 0
        var eventsScanned = 0
        var candidatesInserted = 0
        var dropsByReason: [String: Int] = [:]
    }

    private static let headDigestSpan = 4096
    private static let checkpointLineInterval = 512
    /// Tools repeated at least this often in one tick synthesize a workflow
    /// candidate (mirrors the Stage-0 harness).
    private static let workflowToolRunThreshold = 3

    private let store: ControlPlaneStore
    private let sessionsRootURL: URL
    private let isEnabled: @Sendable () -> Bool
    private let policy: UsageMemoryCurationPolicy
    private let fileManager: FileManager
    private let maxFilesPerTick: Int
    private let wallClockLimit: TimeInterval
    private let fileByteBudget: Int64
    private let memoryCeilingBytes: Int64
    private let openFileForReading: @Sendable (String) -> FileHandle?

    init(
        store: ControlPlaneStore,
        sessionsRootURL: URL,
        isEnabled: @escaping @Sendable () -> Bool,
        policy: UsageMemoryCurationPolicy = .defaults,
        fileManager: FileManager = .default,
        maxFilesPerTick: Int = 25,
        wallClockLimit: TimeInterval = 20,
        fileByteBudget: Int64 = 32 * 1024 * 1024,
        memoryCeilingBytes: Int64 = 2 * 1024 * 1024 * 1024,
        openFileForReading: @escaping @Sendable (String) -> FileHandle? = { FileHandle(forReadingAtPath: $0) }
    ) {
        self.store = store
        self.sessionsRootURL = sessionsRootURL
        self.isEnabled = isEnabled
        self.policy = policy
        self.fileManager = fileManager
        self.maxFilesPerTick = max(1, maxFilesPerTick)
        self.wallClockLimit = wallClockLimit
        self.fileByteBudget = fileByteBudget
        self.memoryCeilingBytes = memoryCeilingBytes
        self.openFileForReading = openFileForReading
    }

    // MARK: - Tick

    func mineTick(now: Date = Date()) async throws -> TickReport {
        // Dormancy invariant: a disabled miner performs ZERO file and ZERO
        // database work — the gate check precedes even the cursor load.
        guard isEnabled() else { return TickReport() }

        var report = TickReport()
        var cursors = await loadCursors()
        var cursorsChanged = false
        var batch: [UsageMemoryCandidate] = []
        var abortError: Error?

        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(
                fileByteBudget: fileByteBudget,
                memoryCeilingBytes: memoryCeilingBytes
            )
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        let files = rolloutFileURLs()

        for (index, fileURL) in files.enumerated() {
            if report.filesRead >= maxFilesPerTick
                || ProcessInfo.processInfo.systemUptime - startedAt > wallClockLimit {
                report.filesDeferred += files.count - index
                break
            }

            let path = fileURL.standardizedFileURL.path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path), // try?-ok(unstatable file retries next tick)
                  let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
                  fileSize > 0 else {
                continue // empty or unstatable: nothing to cover yet
            }
            let mtime = attributes[.modificationDate] as? Date

            // mtime pre-filter: an unchanged, fully-covered file is skipped
            // on stat alone (size equality guards same-second appends).
            if let cursor = cursors[path],
               let lastMtime = cursor.lastMtime,
               let mtime,
               mtime.timeIntervalSince1970 <= lastMtime,
               fileSize == cursor.byteOffset {
                continue
            }

            let result = await mineFile(
                path: path,
                fileSize: fileSize,
                mtime: mtime,
                previousCursor: cursors[path],
                governor: governor,
                now: now
            )

            if result.deferred {
                report.filesDeferred += 1
                continue
            }
            report.filesRead += 1
            report.bytesRead += result.bytesRead
            report.eventsScanned += result.eventsScanned
            batch.append(contentsOf: result.candidates)
            for (reason, count) in result.drops {
                report.dropsByReason[reason, default: 0] += count
            }
            if let cursor = result.cursor, cursor != cursors[path] {
                cursors[path] = cursor
                cursorsChanged = true
            }
            if let error = result.abort {
                // Memory ceiling mid-file: partial progress (cursor at the
                // last terminated line consumed) is still a safe resume
                // point. Persist what we have, then surface the abort.
                abortError = error
                break
            }
        }

        if batch.isEmpty == false || cursorsChanged {
            report.candidatesInserted = try await store.insertUsageMemoryCandidates(
                batch,
                cursorKey: ControlPlaneStore.usageSessionMinerCursorKey,
                cursorJSON: try encodeCursors(cursors),
                now: now
            )
        }
        if let abortError { throw abortError }
        return report
    }

    // MARK: - Per-file scan

    private struct FileMineResult {
        var cursor: MinerFileCursor?
        var candidates: [UsageMemoryCandidate] = []
        var eventsScanned = 0
        var bytesRead: Int64 = 0
        var drops: [String: Int] = [:]
        var abort: Error?
        var deferred = false
    }

    private func mineFile(
        path: String,
        fileSize: Int64,
        mtime: Date?,
        previousCursor: MinerFileCursor?,
        governor: ParserResourceGovernor,
        now: Date
    ) async -> FileMineResult {
        var result = FileMineResult()

        let canResume: Bool
        if let previous = previousCursor {
            canResume = previous.byteOffset >= 0
                && previous.byteOffset <= fileSize
                && previous.headDigestLength > 0
                && previous.headDigestLength <= Self.headDigestSpan
                && Int64(previous.headDigestLength) <= fileSize
        } else {
            canResume = false
        }

        // Admit the probe plus the expected tail up front; a rewrite admits
        // the remainder below so a restarted file totals one full read.
        let probeBytes = canResume ? Int64(previousCursor?.headDigestLength ?? 0) : 0
        let expectedBytes = canResume
            ? probeBytes + max(fileSize - (previousCursor?.byteOffset ?? 0), 0)
            : fileSize
        guard governor.admitFile(estimatedBytes: expectedBytes) else {
            result.deferred = true
            return result
        }
        guard let handle = openFileForReading(path) else {
            result.deferred = true
            return result
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        var resumeOffset: Int64 = 0
        var headDigest: UInt64
        var headDigestLength: Int

        if let previous = previousCursor, canResume {
            let observed = parserAutoReleasePool {
                ParserScanDigest.fnv1a64(handle.readData(ofLength: previous.headDigestLength))
            }
            if observed == previous.headDigest {
                resumeOffset = previous.byteOffset
                headDigest = previous.headDigest
                headDigestLength = previous.headDigestLength
            } else {
                // Rewritten file: restart at byte zero. The tail span was
                // already admitted; charge the previously-covered remainder.
                guard governor.admitFile(estimatedBytes: previous.byteOffset) else {
                    result.deferred = true
                    return result
                }
                headDigestLength = Int(min(Int64(Self.headDigestSpan), fileSize))
                try? handle.seek(toOffset: 0) // try?-ok(head re-read falls back to current position)
                headDigest = parserAutoReleasePool {
                    ParserScanDigest.fnv1a64(handle.readData(ofLength: headDigestLength))
                }
            }
        } else {
            headDigestLength = Int(min(Int64(Self.headDigestSpan), fileSize))
            headDigest = parserAutoReleasePool {
                ParserScanDigest.fnv1a64(handle.readData(ofLength: headDigestLength))
            }
        }

        result.bytesRead = probeBytes + max(fileSize - resumeOffset, 0)

        try? handle.seek(toOffset: UInt64(resumeOffset)) // try?-ok(seek failure reads from head; dedup absorbs the replay)
        let reader = BufferedLineReader(fileHandle: handle, startOffset: resumeOffset)
        let threadID = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let sourceRef = "codex:\(threadID)"

        var persistedOffset = resumeOffset
        var toolRuns: [String: Int] = [:]
        var lineCount = 0

        while let line = reader.nextLine() {
            // Unterminated trailing line: a live writer may be mid-append.
            // Never consume it and never let the cursor cover it — the next
            // tick re-reads it once the terminator lands.
            guard line.isTerminated else { break }
            lineCount += 1
            if lineCount % Self.checkpointLineInterval == 0 {
                do {
                    try governor.checkpoint()
                } catch {
                    result.abort = error
                    break
                }
            }

            // 2026-07-16 discipline: the JSONSerialization object graph is
            // autoreleased — drain it per line or a multi-GB corpus walk
            // climbs to the governor ceiling.
            let outcome = parserAutoReleasePool { Self.classify(lineText: line.text) }
            persistedOffset = line.endOffset

            switch outcome {
            case .notJSON:
                continue
            case .skipped:
                result.eventsScanned += 1
            case .toolRun(let name):
                result.eventsScanned += 1
                toolRuns[name, default: 0] += 1
            case .userMessage(let text):
                result.eventsScanned += 1
                await gate(
                    text: text,
                    role: "user",
                    sourceRef: sourceRef,
                    now: now,
                    into: &result
                )
            }
        }

        // Synthesized workflow candidates: ≥3 runs of the same tool this
        // tick, same text shape as the Stage-0 harness. Skipped after an
        // abort — the tally is incomplete.
        if result.abort == nil {
            for (tool, runs) in toolRuns.sorted(by: { $0.key < $1.key })
            where runs >= Self.workflowToolRunThreshold {
                await gate(
                    text: "Repeatedly runs the \(tool) tool (\(runs)x this session).",
                    role: "workflow",
                    sourceRef: sourceRef,
                    now: now,
                    into: &result
                )
            }
        }

        result.cursor = MinerFileCursor(
            byteOffset: persistedOffset,
            headDigest: headDigest,
            headDigestLength: headDigestLength,
            lastMtime: mtime?.timeIntervalSince1970
        )
        return result
    }

    // MARK: - Stage-0 gate

    private func gate(
        text: String,
        role: String,
        sourceRef: String,
        now: Date,
        into result: inout FileMineResult
    ) async {
        let simhash = UsageMemorySimHash.storageValue(UsageMemorySimHash.hash(text))
        var repetitionCount = 0
        if role == "user" {
            let window = now.addingTimeInterval(-Double(policy.caps.candidateTTLDays) * 86_400)
            repetitionCount = (try? await store.usageCandidateRepetitionCount( // try?-ok(missing repetition signal only lowers salience)
                sourceKind: .agentSession,
                simhash: simhash,
                since: window
            )) ?? 0
        }

        let verdict = UsageMemoryCandidateGate.evaluate(
            UsageMemoryCandidateGate.Input(
                sourceKind: .agentSession,
                text: text,
                sourceRef: sourceRef,
                threadLogicalID: sourceRef,
                role: role,
                repetitionCount: repetitionCount
            ),
            policy: policy
        )
        switch verdict {
        case .accept(let salienceHint):
            if let candidate = makeCandidate(
                text: text,
                role: role,
                sourceRef: sourceRef,
                salienceHint: salienceHint,
                simhash: simhash,
                now: now
            ) {
                result.candidates.append(candidate)
            }
        case .drop(let reason):
            result.drops[reason.rawValue, default: 0] += 1
        }
    }

    private struct CandidatePayload: Codable {
        let schemaVersion: Int
        let text: String
        let role: String
        let threadLogicalID: String
        let observedAt: Date
    }

    /// Builds the spool row. `payload_json` carries ONLY the gated text plus
    /// role/thread/time metadata — never raw line content.
    private func makeCandidate(
        text: String,
        role: String,
        sourceRef: String,
        salienceHint: Double,
        simhash: Int64,
        now: Date
    ) -> UsageMemoryCandidate? {
        let payload = CandidatePayload(
            schemaVersion: 1,
            text: text,
            role: role,
            threadLogicalID: sourceRef,
            observedAt: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let payloadData = try? encoder.encode(payload) else { return nil } // try?-ok(unencodable payload drops the candidate)
        let contentHash = UsageMemoryCandidate.contentHash(ofText: text)
        return UsageMemoryCandidate(
            id: UsageMemoryCandidate.spoolID(sourceRef: sourceRef, contentHash: contentHash),
            sourceKind: .agentSession,
            sourceRef: sourceRef,
            threadLogicalID: sourceRef,
            payloadJSON: String(decoding: payloadData, as: UTF8.self),
            contentHash: contentHash,
            simhash: simhash,
            salienceHint: salienceHint
        )
    }

    // MARK: - Line classification

    private enum LineOutcome {
        case notJSON
        case skipped
        case toolRun(name: String)
        case userMessage(text: String)
    }

    /// Payload-as-item shim, verbatim from the Stage-0 harness: current
    /// rollouts carry the response item directly in `payload`
    /// (`payload.role`/`payload.content`), which `extractCodexMessage`
    /// reaches by re-wrapping as `{"item": payload}`. `event_msg` /
    /// `user_message` lines duplicate the same message text without a `role`
    /// field, so both extraction paths return nil for them — no double
    /// counting.
    private static func classify(lineText: String) -> LineOutcome {
        guard let data = lineText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
            return .notJSON
        }
        let payload = json["payload"] as? [String: Any]
        let payloadType = payload?["type"] as? String

        if payloadType == "function_call" || payloadType == "local_shell_call"
            || payloadType == "custom_tool_call" || payload?["tool_name"] != nil {
            if let payload, let tool = CodexSessionLogScanner.extractCodexTool(from: ["item": payload]) {
                return .toolRun(name: tool.name)
            }
            return .skipped
        }

        let message = CodexSessionLogScanner.extractCodexMessage(from: json)
            ?? payload.flatMap { CodexSessionLogScanner.extractCodexMessage(from: ["item": $0]) }
        guard let message, message.role == "user" else { return .skipped }
        return .userMessage(text: message.text)
    }

    // MARK: - Cursor persistence

    private func loadCursors() async -> [String: MinerFileCursor] {
        guard let json = try? await store.usageSessionMinerCursorJSON(), // try?-ok(unreadable cursor cold-starts; dedup absorbs the replay)
              let data = json.data(using: .utf8),
              let cursors = try? JSONDecoder().decode([String: MinerFileCursor].self, from: data) else { // try?-ok(corrupt cursor cold-starts)
            return [:]
        }
        return cursors
    }

    private func encodeCursors(_ cursors: [String: MinerFileCursor]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(cursors), as: UTF8.self)
    }

    // MARK: - Discovery

    private func rolloutFileURLs() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}
