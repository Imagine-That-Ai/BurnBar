import Foundation
import OpenBurnBarKernel

public struct AntigravityQuotaAdapter: ProviderQuotaAdapter {
    public init() {}

    // MARK: - Model Catalog

    /// Antigravity quota windows refresh every 5 hours (Pro/Ultra).
    /// See: https://blog.google/feed/new-antigravity-rate-limits-pro-ultra-subsribers/
    static let quotaWindowSeconds: TimeInterval = 5 * 60 * 60

    struct ModelTier {
        let name: String
        /// Estimated requests per 5-hour window. Google uses a credit-based
        /// system and does not publish exact per-model request limits.
        /// These are best-effort estimates based on community observation.
        let windowCap: Double
    }

    static let availableModels: [ModelTier] = [
        ModelTier(name: "Gemini 3.7 Flash (High)", windowCap: 600),
        ModelTier(name: "Gemini 3.7 Flash (Medium)", windowCap: 900),
        ModelTier(name: "Gemini 3.7 Flash (Low)", windowCap: 1200),
        ModelTier(name: "Gemini 3.5 Flash (High)", windowCap: 600),
        ModelTier(name: "Gemini 3.5 Flash (Medium)", windowCap: 900),
        ModelTier(name: "Gemini 3.1 Pro (High)", windowCap: 150),
        ModelTier(name: "Gemini 3.1 Pro (Low)", windowCap: 300),
        ModelTier(name: "Claude Sonnet 4.6 (Thinking)", windowCap: 120),
        ModelTier(name: "Claude Opus 4.6 (Thinking)", windowCap: 60),
        ModelTier(name: "GPT-OSS 120B (Medium)", windowCap: 240)
    ]

    static let defaultModelName = "Claude Opus 4.6 (Thinking)"

    // MARK: - Codable Types

    struct HistoryEvent: Codable {
        let timestamp: Double
        let display: String?
        let workspace: String?
    }

    struct SettingsFile: Codable {
        let model: String?
    }

    // MARK: - Helpers

    /// Convert a model name to a stable snake_case key fragment.
    static func snakeCaseKey(for name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: ".", with: "_")
    }

    private static func candidateRoots(from context: ProviderQuotaAdapterContext) -> [URL] {
        var candidates: [URL] = []
        candidates.append(context.homeDirectoryURL.appendingPathComponent(".gemini/antigravity", isDirectory: true))
        candidates.append(context.homeDirectoryURL.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true))
        candidates.append(context.homeDirectoryURL.appendingPathComponent(".antigravity", isDirectory: true))
        return candidates
    }

    private static func resolveHistoryURL(candidateRoots: [URL], fileManager: FileManager) -> URL? {
        for root in candidateRoots {
            let url = root.appendingPathComponent("history.jsonl")
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func resolveSettingsURL(candidateRoots: [URL], context: ProviderQuotaAdapterContext) -> URL? {
        for root in candidateRoots {
            let url = root.appendingPathComponent("settings.json")
            if context.fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        let geminiSettings = context.homeDirectoryURL.appendingPathComponent(".gemini/settings.json")
        if context.fileManager.fileExists(atPath: geminiSettings.path) {
            return geminiSettings
        }
        return nil
    }

    // MARK: - Fetch

    /// Test-only deterministic clock override. Release builds never honor this
    /// environment seam, and debug builds require an explicit opt-in flag so a
    /// stray production-like environment cannot move quota windows.
    static let referenceDateEnvironmentKey = "OPENBURNBAR_QUOTA_REFERENCE_MS"
    static let referenceDateOptInEnvironmentKey = "OPENBURNBAR_ENABLE_TEST_QUOTA_REFERENCE_MS"
    private static let minimumReferenceDateMilliseconds = 946_684_800_000.0 // 2000-01-01T00:00:00Z
    private static let maximumReferenceDateMilliseconds = 4_102_444_800_000.0 // 2100-01-01T00:00:00Z

    static func referenceDate(from context: ProviderQuotaAdapterContext) -> Date {
        #if DEBUG
        guard context.environment[referenceDateOptInEnvironmentKey] == "1" else {
            return Date()
        }
        guard let raw = context.environment[referenceDateEnvironmentKey],
              let milliseconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              milliseconds.isFinite,
              milliseconds >= minimumReferenceDateMilliseconds,
              milliseconds <= maximumReferenceDateMilliseconds else {
            return Date()
        }
        return Date(timeIntervalSince1970: milliseconds / 1000.0)
        #else
        return Date()
        #endif
    }

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let roots = Self.candidateRoots(from: context)
        let historyURL = Self.resolveHistoryURL(candidateRoots: roots, fileManager: context.fileManager)
        let settingsURL = Self.resolveSettingsURL(candidateRoots: roots, context: context)
        let now = Self.referenceDate(from: context)

        // Check if any candidate base directory exists
        let hasAnySource = historyURL != nil || roots.contains {
            context.fileManager.fileExists(atPath: $0.path)
        }

        guard hasAnySource else {
            return ProviderQuotaSnapshot(
                provider: .antigravity,
                fetchedAt: now,
                source: .unavailable,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: "Antigravity session logs not found at ~/.gemini/antigravity or ~/.gemini/antigravity-cli",
                buckets: []
            )
        }

        do {
            let windowSeconds = Self.quotaWindowSeconds
            var historyScan: HistoryLogScan?
            if let historyURL {
                historyScan = Self.scanHistoryLog(
                    at: historyURL,
                    fileManager: context.fileManager,
                    now: now
                )
            }

            let transcriptScan = Self.scanTranscripts(
                candidateRoots: roots,
                fileManager: context.fileManager,
                now: now
            )

            // Determine active model
            let activeModelName: String = {
                if let settingsURL,
                   context.fileManager.fileExists(atPath: settingsURL.path),
                   let settingsData = try? Data(contentsOf: settingsURL),
                   let settings = try? JSONDecoder().decode(SettingsFile.self, from: settingsData),
                   let model = settings.model, !model.isEmpty {
                    return model
                }
                if let model = transcriptScan.latestModel, !model.isEmpty {
                    return model
                }
                return Self.defaultModelName
            }()

            // Combine in-window event count and earliest reset timestamp
            var inWindowCount = 0
            var earliestInWindowTimestamp: Double?
            var sawAnyEvent = false

            if let historyScan, historyScan.inWindowCount > 0 {
                inWindowCount = max(inWindowCount, historyScan.inWindowCount)
                if let ts = historyScan.earliestInWindowTimestamp {
                    earliestInWindowTimestamp = min(earliestInWindowTimestamp ?? ts, ts)
                }
                sawAnyEvent = true
            }

            if transcriptScan.inWindowCount > 0 {
                inWindowCount = max(inWindowCount, transcriptScan.inWindowCount)
                if let ts = transcriptScan.earliestInWindowTimestamp {
                    earliestInWindowTimestamp = min(earliestInWindowTimestamp ?? ts, ts)
                }
                sawAnyEvent = true
            }

            if !sawAnyEvent {
                sawAnyEvent = (historyScan?.sawAnyEvent == true) || transcriptScan.sawAnyEvent
            }

            guard sawAnyEvent else {
                return ProviderQuotaSnapshot(
                    provider: .antigravity,
                    fetchedAt: now,
                    source: .unavailable,
                    confidence: .unavailable,
                    managementURL: nil,
                    statusMessage: "Antigravity session logs not found at ~/.gemini/antigravity or ~/.gemini/antigravity-cli",
                    buckets: []
                )
            }

            let usedCount = Double(inWindowCount)
            var resetsAt: Date?
            if let earliestTimestamp = earliestInWindowTimestamp {
                resetsAt = Date(timeIntervalSince1970: earliestTimestamp / 1000.0)
                    .addingTimeInterval(windowSeconds)
            }

            // --- Build per-model buckets ---
            var buckets: [ProviderQuotaBucket] = []

            // Active model bucket first.
            let activeModelTier = Self.availableModels.first(where: { $0.name == activeModelName })
            let activeCap = activeModelTier?.windowCap ?? 60.0
            let activeRemaining = max(0.0, activeCap - usedCount)

            let activeBucket = ProviderQuotaBucket(
                key: "active_model_\(Self.snakeCaseKey(for: activeModelName))",
                label: "\(activeModelName) (Active)",
                windowKind: .rollingHours,
                usedValue: usedCount,
                limitValue: activeCap,
                remainingValue: activeRemaining,
                usedPercent: (usedCount / activeCap) * 100.0,
                resetsAt: resetsAt,
                unit: .requests,
                isEstimated: true
            )
            buckets.append(activeBucket)

            // Inactive model buckets — full headroom, no resetsAt.
            for model in Self.availableModels where model.name != activeModelName {
                let bucket = ProviderQuotaBucket(
                    key: "model_\(Self.snakeCaseKey(for: model.name))",
                    label: model.name,
                    windowKind: .rollingHours,
                    usedValue: 0,
                    limitValue: model.windowCap,
                    remainingValue: model.windowCap,
                    usedPercent: 0,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: true
                )
                buckets.append(bucket)
            }

            return ProviderQuotaSnapshot(
                provider: .antigravity,
                fetchedAt: now,
                source: .localCLI,
                confidence: .estimated,
                managementURL: nil,
                statusMessage: "Active model: \(activeModelName). Rolling 5h quota across \(Self.availableModels.count) model tiers. Caps are community-estimated.",
                buckets: buckets
            )
        } catch {
            return ProviderQuotaSnapshot(
                provider: .antigravity,
                fetchedAt: now,
                source: .unavailable,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: "Error reading Antigravity session logs: \(error.localizedDescription)",
                buckets: []
            )
        }
    }

    // MARK: - Transcript Scanning Fallback

    struct TranscriptScanResult: Equatable, Sendable {
        var inWindowCount: Int
        var earliestInWindowTimestamp: Double?
        var latestModel: String?
        var sawAnyEvent: Bool
        var bytesRead: Int
    }

    static func scanTranscripts(
        candidateRoots: [URL],
        fileManager: FileManager,
        now: Date
    ) -> TranscriptScanResult {
        let windowSeconds = quotaWindowSeconds
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let cutoffMs = cutoff.timeIntervalSince1970 * 1000.0
        let nowMs = now.timeIntervalSince1970 * 1000.0

        var inWindowCount = 0
        var earliestInWindowTimestamp: Double?
        var latestModel: String?
        var sawAnyEvent = false
        var bytesRead = 0
        var seenSessionIds = Set<String>()

        for root in candidateRoots {
            let brainDir = root.appendingPathComponent("brain", isDirectory: true)
            guard fileManager.fileExists(atPath: brainDir.path) else { continue }
            guard let sessionDirs = try? fileManager.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            ) else { continue }

            for sessionDir in sessionDirs {
                let sessionId = sessionDir.lastPathComponent
                guard seenSessionIds.insert(sessionId).inserted else { continue }

                let logsDir = sessionDir.appendingPathComponent(".system_generated/logs", isDirectory: true)
                let transcriptFile = logsDir.appendingPathComponent("transcript.jsonl")
                let transcriptFullPath = logsDir.appendingPathComponent("transcript_full.jsonl")
                let file = fileManager.fileExists(atPath: transcriptFullPath.path) ? transcriptFullPath : transcriptFile
                guard fileManager.fileExists(atPath: file.path) else { continue }

                guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }

                sawAnyEvent = true
                guard mtime >= cutoff else { continue }

                guard let data = try? Data(contentsOf: file),
                      let text = String(data: data, encoding: .utf8) else { continue }
                bytesRead += data.count

                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                    let source = json["source"] as? String ?? ""
                    let type = json["type"] as? String ?? ""
                    let content = json["content"] as? String ?? ""
                    let createdAtStr = json["created_at"] as? String

                    if (source == "USER_EXPLICIT" || type == "USER_INPUT") && content.contains("Model Selection") {
                        if let model = extractModelFromSettingsChange(content) {
                            latestModel = model
                        }
                    }

                    if (source == "MODEL" && type == "PLANNER_RESPONSE") || source == "USER_EXPLICIT" || type == "USER_INPUT" || source == "USER" {
                        if let createdAtStr,
                           let date = ThreadSafeISO8601DateFormatter.parse(createdAtStr) {
                            let tsMs = date.timeIntervalSince1970 * 1000.0
                            if tsMs >= cutoffMs && tsMs <= nowMs {
                                inWindowCount += 1
                                earliestInWindowTimestamp = min(earliestInWindowTimestamp ?? tsMs, tsMs)
                            }
                        }
                    }
                }
            }
        }

        return TranscriptScanResult(
            inWindowCount: inWindowCount,
            earliestInWindowTimestamp: earliestInWindowTimestamp,
            latestModel: latestModel,
            sawAnyEvent: sawAnyEvent,
            bytesRead: bytesRead
        )
    }

    private static func extractModelFromSettingsChange(_ content: String) -> String? {
        guard content.contains("Model Selection") else { return nil }
        guard let range = content.range(of: "Model Selection` from ", options: .caseInsensitive) else {
            return nil
        }
        let afterPrefix = content[range.upperBound...]
        guard let toRange = afterPrefix.range(of: " to ", options: .caseInsensitive) else {
            return nil
        }
        let afterTo = afterPrefix[toRange.upperBound...]
        var candidate = String(afterTo)
        if let tagEndRange = candidate.range(of: "</") {
            candidate = String(candidate[..<tagEndRange.lowerBound])
        }
        if let dotSpaceRange = candidate.range(of: ". ") {
            candidate = String(candidate[..<dotSpaceRange.lowerBound])
        } else if let dotNewline = candidate.range(of: ".\n") {
            candidate = String(candidate[..<dotNewline.lowerBound])
        } else if candidate.hasSuffix(".") {
            candidate = String(candidate.dropLast())
        }

        let model = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    // MARK: - JSONL tail scan

    struct HistoryLogScan: Equatable, Sendable {
        var inWindowCount: Int
        var earliestInWindowTimestamp: Double?
        var sawAnyEvent: Bool
        var bytesRead: Int
    }

    static let historyTailChunkBytes = 64 * 1024

    static func scanHistoryLog(
        at historyURL: URL,
        fileManager: FileManager,
        now: Date,
        chunkBytes: Int = historyTailChunkBytes
    ) -> HistoryLogScan? {
        guard fileManager.fileExists(atPath: historyURL.path) else {
            return HistoryLogScan(inWindowCount: 0, earliestInWindowTimestamp: nil, sawAnyEvent: false, bytesRead: 0)
        }
        let windowSeconds = quotaWindowSeconds
        let cutoffMs = now.addingTimeInterval(-windowSeconds).timeIntervalSince1970 * 1000.0
        let nowMs = now.timeIntervalSince1970 * 1000.0
        let decoder = JSONDecoder()
        return scanHistoryLogFromEnd(
            at: historyURL,
            cutoffMs: cutoffMs,
            nowMs: nowMs,
            chunkBytes: chunkBytes,
            decoder: decoder
        ) ?? fallbackFullHistoryRead(
            at: historyURL,
            cutoffMs: cutoffMs,
            nowMs: nowMs,
            decoder: decoder
        )
    }

    private static func scanHistoryLogFromEnd(
        at historyURL: URL,
        cutoffMs: Double,
        nowMs: Double,
        chunkBytes: Int,
        decoder: JSONDecoder
    ) -> HistoryLogScan? {
        do {
            let handle = try FileHandle(forReadingFrom: historyURL)
            defer { try? handle.close() } // try?-ok(handle teardown)
            let fileSize = try handle.seekToEnd()
            var offset = fileSize
            var suffixCarry = Data()
            var bytesRead = 0
            var inWindowCount = 0
            var earliestInWindowTimestamp: Double?
            var sawAnyEvent = false
            var reachedOlder = false

            while offset > 0, !reachedOlder {
                let chunkLen = min(UInt64(max(chunkBytes, 1)), offset)
                offset -= chunkLen
                try handle.seek(toOffset: offset)
                var data = try handle.read(upToCount: Int(chunkLen)) ?? Data()
                bytesRead += data.count
                if !suffixCarry.isEmpty {
                    data.append(suffixCarry)
                }

                let atStart = offset == 0
                if !atStart {
                    if let newline = data.firstIndex(of: 0x0A) {
                        suffixCarry = Data(data[..<newline])
                        data = Data(data[data.index(after: newline)...])
                    } else {
                        suffixCarry = data
                        continue
                    }
                } else {
                    suffixCarry = Data()
                }

                guard let text = String(data: data, encoding: .utf8) else {
                    return nil
                }

                var newestInChunk: Double?
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let lineData = trimmed.data(using: .utf8),
                          let event = try? decoder.decode(HistoryEvent.self, from: lineData) else { // try?-ok(skip malformed line)
                        continue
                    }
                    sawAnyEvent = true
                    let timestamp = event.timestamp
                    newestInChunk = max(newestInChunk ?? timestamp, timestamp)
                    if timestamp >= cutoffMs && timestamp <= nowMs {
                        inWindowCount += 1
                        earliestInWindowTimestamp = min(earliestInWindowTimestamp ?? timestamp, timestamp)
                    }
                }
                if let newestInChunk, newestInChunk < cutoffMs {
                    reachedOlder = true
                }
            }

            return HistoryLogScan(
                inWindowCount: inWindowCount,
                earliestInWindowTimestamp: earliestInWindowTimestamp,
                sawAnyEvent: sawAnyEvent,
                bytesRead: bytesRead
            )
        } catch {
            return nil
        }
    }

    private static func fallbackFullHistoryRead(
        at historyURL: URL,
        cutoffMs: Double,
        nowMs: Double,
        decoder: JSONDecoder
    ) -> HistoryLogScan? {
        guard let data = try? Data(contentsOf: historyURL), // try?-ok(UTF-8 fail-closed)
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var inWindowCount = 0
        var earliestInWindowTimestamp: Double?
        var sawAnyEvent = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let event = try? decoder.decode(HistoryEvent.self, from: lineData) else { // try?-ok(skip malformed line)
                continue
            }
            sawAnyEvent = true
            let timestamp = event.timestamp
            if timestamp >= cutoffMs && timestamp <= nowMs {
                inWindowCount += 1
                earliestInWindowTimestamp = min(earliestInWindowTimestamp ?? timestamp, timestamp)
            }
        }
        return HistoryLogScan(
            inWindowCount: inWindowCount,
            earliestInWindowTimestamp: earliestInWindowTimestamp,
            sawAnyEvent: sawAnyEvent,
            bytesRead: data.count
        )
    }
}
