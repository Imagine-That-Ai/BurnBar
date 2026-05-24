import Foundation
import OpenBurnBarCore

// MARK: - SuperGrok Usage Log
//
// Per-prompt JSONL log used by `XAIQuotaAdapter` (SuperGrok pacing branch)
// to estimate prompts-in-rolling-2h-window for the consumer tiers.
//
// xAI does not publish a consumer-quota API for SuperGrok Lite / SuperGrok /
// SuperGrok Heavy; the adapter therefore computes a best-effort estimate by
// counting events in this log over the last 2 hours and comparing against
// the published cap for the active tier. Caps live on
// `XAIQuotaPlanTier.rollingTwoHourPromptCap` and may drift over time —
// downstream snapshots are flagged `confidence: .estimated`.
//
// Writers append one line every time the routing layer dispatches a prompt
// to xAI, regardless of which inference key actually services the call.
// Two emit sites today:
//
// - `ProviderQuotaService.appendRoutingEvent` whenever the recorded
//   decision targets `ProviderID.xAI` and a consumer SuperGrok tier is
//   active (calls `recordPromptDispatched`).
// - Future: any downstream hook that observes outbound xAI traffic can
//   call the same `recordPromptDispatched(...)` entry point.

enum XAISuperGrokUsageLog {

    private struct Event: Codable {
        let timestamp: Double           // ms since epoch
        let model: String?
        let plan: String?
        let source: String?
    }

    /// Append one event line to the SuperGrok usage log.
    ///
    /// Failures are silent — this is a best-effort estimator, not an audit
    /// trail. If the log can't be written the adapter degrades to "no
    /// SuperGrok prompts observed yet" rather than failing the refresh.
    static func recordPromptDispatched(
        plan: XAIQuotaPlanTier,
        model: String? = nil,
        source: String? = nil,
        at date: Date = Date(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        // GrokBuild does not use the pacing log — credits are read from
        // the Management API. Avoid polluting the file when the developer
        // tier is selected.
        guard plan.isSuperGrokConsumer else { return }

        let url = XAIQuotaAdapter.superGrokLogURL(homeDirectoryURL: homeDirectoryURL)
        let event = Event(
            timestamp: date.timeIntervalSince1970 * 1000.0,
            model: model,
            plan: plan.rawValue,
            source: source
        )

        do {
            let directory = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(event)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if let bytes = line.data(using: .utf8) {
                    try? handle.write(contentsOf: bytes)
                }
            } else {
                // File didn't exist yet — create it.
                try line.data(using: .utf8)?.write(to: url, options: .atomic)
            }

            // Soft cap on file size: rewrite to retain only the last 7
            // days of events so the log never grows unbounded. The
            // adapter only ever looks at the last 2h, but tests + future
            // analytics may want a longer trailing tail.
            pruneIfNeeded(at: url, retain: 7 * 24 * 60 * 60, fileManager: fileManager)
        } catch {
            AppLogger.dataStore.silentFailure("XAISuperGrokUsageLog: failed to record event", error: error)
        }
    }

    // MARK: - Pruning

    private static func pruneIfNeeded(
        at url: URL,
        retain seconds: TimeInterval,
        fileManager: FileManager
    ) {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > 256 * 1024 else {
            return
        }

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-seconds).timeIntervalSince1970 * 1000.0
        let decoder = JSONDecoder()
        let lines = text.split(separator: "\n").compactMap { (segment) -> String? in
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let event = try? decoder.decode(Event.self, from: lineData),
                  event.timestamp >= cutoff else {
                return nil
            }
            return trimmed
        }

        let rewritten = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? rewritten.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
