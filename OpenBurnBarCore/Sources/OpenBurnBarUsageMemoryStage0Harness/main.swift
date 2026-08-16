import Foundation
import OpenBurnBarCore

// OpenBurnBarUsageMemoryStage0Harness — offline drop-rate proof for the
// usage-memory Stage-0 candidate gate.
//
// Walks a recorded agent-session corpus (~/.codex/sessions by default),
// replays every rollout event through `UsageMemoryCandidateGate`, and prints
// the accept count, the drop-reason histogram, throughput, and a projected
// candidates/day figure. This is the evidence artifact for "thousands of raw
// events/day → tens of candidates/day" — run it on the real corpus and paste
// the numbers into the PR body.
//
// Incident discipline (2026-07-16): reads ride `BufferedLineReader` (bounded
// memory, memchr line scanning) under a `ParserResourceGovernor` (byte budget
// + memory ceiling + periodic checkpoints). The harness never opens the codex
// SQLite index and never writes anything.
//
// Never-referenced-leaf executable target: no product, absent from
// project.yml — `swift run OpenBurnBarUsageMemoryStage0Harness` only.

struct HarnessOptions {
    var corpusURL: URL
    var maxFiles: Int?
    var maxBytes: Int64?
    var jsonOutput = false

    static func parse(_ arguments: [String]) -> HarnessOptions {
        var options = HarnessOptions(
            corpusURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        )
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--corpus":
                index += 1
                if index < arguments.count {
                    options.corpusURL = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
                }
            case "--max-files":
                index += 1
                if index < arguments.count { options.maxFiles = Int(arguments[index]) }
            case "--max-bytes":
                index += 1
                if index < arguments.count { options.maxBytes = Int64(arguments[index]) }
            case "--json":
                options.jsonOutput = true
            default:
                FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
                exit(2)
            }
            index += 1
        }
        return options
    }
}

let options = HarnessOptions.parse(CommandLine.arguments)
let fileManager = FileManager.default

guard fileManager.fileExists(atPath: options.corpusURL.path) else {
    FileHandle.standardError.write(Data("corpus not found: \(options.corpusURL.path)\n".utf8))
    exit(1)
}

// Enumerate rollout files (sorted for deterministic output).
var rolloutFiles: [URL] = []
if let enumerator = fileManager.enumerator(
    at: options.corpusURL,
    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
    options: [.skipsHiddenFiles]
) {
    for case let url as URL in enumerator {
        if url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" {
            rolloutFiles.append(url)
        }
    }
}
rolloutFiles.sort { $0.path < $1.path }
if let maxFiles = options.maxFiles {
    rolloutFiles = Array(rolloutFiles.prefix(maxFiles))
}

let governor = ParserResourceGovernor(
    limits: ParserResourceLimits(
        fileByteBudget: options.maxBytes,
        memoryCeilingBytes: 4 * 1024 * 1024 * 1024
    )
)

let policy = UsageMemoryCurationPolicy.defaults
var eventCount = 0
var userTurnCount = 0
var acceptCount = 0
var dropCounts: [UsageMemoryCandidateGate.DropReason: Int] = [:]
var bytesRead: Int64 = 0
var filesRead = 0
var filesDeferred = 0
var oldestEvent: Date?
var newestEvent: Date?
let started = Date()

fileLoop: for fileURL in rolloutFiles {
    let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
    let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    guard governor.admitFile(estimatedBytes: fileSize) else {
        filesDeferred += 1
        continue
    }
    if let modified = attributes?[.modificationDate] as? Date {
        oldestEvent = min(oldestEvent ?? modified, modified)
        newestEvent = max(newestEvent ?? modified, modified)
    }
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
    defer { try? handle.close() }
    filesRead += 1
    bytesRead += fileSize

    let threadID = fileURL.deletingPathExtension().lastPathComponent
    var toolRuns: [String: Int] = [:]
    let reader = BufferedLineReader(fileHandle: handle)
    var aborted = false
    while !aborted {
        // The 2026-07-16 incident lesson: JSONSerialization piles autoreleased
        // objects across a multi-GB loop — drain per line or the footprint
        // climbs to the governor ceiling and the pass aborts.
        // `parserAutoReleasePool` (OpenBurnBarLogParsers, re-exported through
        // OpenBurnBarCore) drains on Darwin and is a passthrough on
        // Linux/Windows, where bare `autoreleasepool` does not exist and
        // breaks the Windows swift build.
        let shouldContinue: Bool = parserAutoReleasePool {
            guard let line = reader.nextLine() else { return false }
            do {
                try governor.checkpoint()
            } catch {
                FileHandle.standardError.write(Data("aborted: \(error)\n".utf8))
                aborted = true
                return false
            }
            guard let data = line.text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return true
            }
            eventCount += 1

            // In current rollouts the payload IS the response item
            // (`payload.role` / `payload.content`), while older shapes nest it
            // at `payload.item` — extractCodexMessage handles the latter, so
            // shim the former by re-wrapping. `event_msg`/`user_message` lines
            // duplicate the same text and are skipped to avoid double counting.
            let payload = json["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String

            if payloadType == "function_call" || payloadType == "local_shell_call"
                || payloadType == "custom_tool_call" || payload?["tool_name"] != nil {
                if let payload, let tool = CodexSessionLogScanner.extractCodexTool(from: ["item": payload]) {
                    toolRuns[tool.name, default: 0] += 1
                }
                return true
            }

            let message = CodexSessionLogScanner.extractCodexMessage(from: json)
                ?? payload.flatMap { CodexSessionLogScanner.extractCodexMessage(from: ["item": $0]) }
            guard let message, message.role == "user" else { return true }

            userTurnCount += 1
            let verdict = UsageMemoryCandidateGate.evaluate(
                UsageMemoryCandidateGate.Input(
                    sourceKind: .agentSession,
                    text: message.text,
                    sourceRef: "codex:\(threadID)",
                    threadLogicalID: "codex:\(threadID)",
                    role: "user"
                ),
                policy: policy
            )
            switch verdict {
            case .accept:
                acceptCount += 1
            case .drop(let reason):
                dropCounts[reason, default: 0] += 1
            }
            return true
        }
        if !shouldContinue { break }
    }
    if aborted { break fileLoop }

    // Synthesized workflow candidates: ≥3 runs of the same tool in a session.
    for (tool, runs) in toolRuns where runs >= 3 {
        let verdict = UsageMemoryCandidateGate.evaluate(
            UsageMemoryCandidateGate.Input(
                sourceKind: .agentSession,
                text: "Repeatedly runs the \(tool) tool (\(runs)x this session).",
                sourceRef: "codex:\(threadID)",
                threadLogicalID: "codex:\(threadID)",
                role: "workflow"
            ),
            policy: policy
        )
        if case .accept = verdict {
            acceptCount += 1
        } else if case .drop(let reason) = verdict {
            dropCounts[reason, default: 0] += 1
        }
    }
}

let elapsed = Date().timeIntervalSince(started)
let corpusDays = max(
    1.0,
    (newestEvent?.timeIntervalSince(oldestEvent ?? Date()) ?? 0) / 86_400
)
let projectedPerDay = Double(acceptCount) / corpusDays
let gatedTotal = userTurnCount + dropCounts[.toolNoise, default: 0]

if options.jsonOutput {
    var payload: [String: Any] = [
        "files_read": filesRead,
        "files_deferred": filesDeferred,
        "bytes_read": bytesRead,
        "events": eventCount,
        "user_turns": userTurnCount,
        "accepted": acceptCount,
        "corpus_days": corpusDays,
        "projected_candidates_per_day": projectedPerDay,
        "elapsed_seconds": elapsed,
    ]
    var drops: [String: Int] = [:]
    for (reason, count) in dropCounts { drops[reason.rawValue] = count }
    payload["drops"] = drops
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
} else {
    print("Stage-0 harness — \(options.corpusURL.path)")
    print(String(format: "files: %d read, %d deferred · %.2f GB · %.1fs · %.1f MB/s",
                 filesRead, filesDeferred,
                 Double(bytesRead) / 1_073_741_824,
                 elapsed,
                 elapsed > 0 ? Double(bytesRead) / 1_048_576 / elapsed : 0))
    print("events scanned: \(eventCount) · user turns gated: \(userTurnCount)")
    print("ACCEPTED: \(acceptCount)  (corpus spans \(String(format: "%.1f", corpusDays)) days ⇒ \(String(format: "%.1f", projectedPerDay)) candidates/day)")
    print("drop histogram:")
    for reason in UsageMemoryCandidateGate.DropReason.allCases {
        let count = dropCounts[reason, default: 0]
        guard count > 0 else { continue }
        let share = gatedTotal > 0 ? Double(count) * 100 / Double(gatedTotal) : 0
        print(String(format: "  %-18@ %8d  (%.1f%%)", reason.rawValue as NSString, count, share))
    }
}
