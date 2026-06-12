import Foundation
import OpenBurnBarCore

struct AntigravityQuotaAdapter: ProviderQuotaAdapter {

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

    // MARK: - Fetch

    /// Test-only deterministic clock override. Production leaves this unset.
    static let referenceDateEnvironmentKey = "OPENBURNBAR_QUOTA_REFERENCE_MS"

    static func referenceDate(from context: ProviderQuotaAdapterContext) -> Date {
        guard let raw = context.environment[referenceDateEnvironmentKey],
              let milliseconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return Date()
        }
        return Date(timeIntervalSince1970: milliseconds / 1000.0)
    }

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let historyURL = context.homeDirectoryURL.appendingPathComponent(".gemini/antigravity-cli/history.jsonl")
        let settingsURL = context.homeDirectoryURL.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        let now = Self.referenceDate(from: context)

        guard context.fileManager.fileExists(atPath: historyURL.path) else {
            return ProviderQuotaSnapshot(
                provider: .antigravity,
                fetchedAt: now,
                source: .unavailable,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: "Antigravity history log not found at ~/.gemini/antigravity-cli/history.jsonl",
                buckets: []
            )
        }

        do {
            // --- Determine active model ---
            let activeModelName: String = {
                guard context.fileManager.fileExists(atPath: settingsURL.path),
                      let settingsData = try? Data(contentsOf: settingsURL),
                      let settings = try? JSONDecoder().decode(SettingsFile.self, from: settingsData),
                      let model = settings.model, !model.isEmpty else {
                    return Self.defaultModelName
                }
                return model
            }()

            // --- Parse history events in rolling 5h quota window ---
            let data = try Data(contentsOf: historyURL)
            guard let contentString = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "AntigravityQuotaAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode history file as UTF-8"])
            }

            let lines = contentString.components(separatedBy: .newlines)
            let decoder = JSONDecoder()
            let windowSeconds = Self.quotaWindowSeconds
            let cutoff = now.addingTimeInterval(-windowSeconds)

            var eventsInWindow: [HistoryEvent] = []

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                guard let lineData = trimmed.data(using: .utf8),
                      let event = try? decoder.decode(HistoryEvent.self, from: lineData) else {
                    continue
                }

                let eventDate = Date(timeIntervalSince1970: event.timestamp / 1000.0)
                if eventDate >= cutoff && eventDate <= now {
                    eventsInWindow.append(event)
                }
            }

            let usedCount = Double(eventsInWindow.count)

            // --- Compute resetsAt from the earliest event in the 5h window ---
            var resetsAt: Date?
            if !eventsInWindow.isEmpty {
                let sortedTimestamps = eventsInWindow.map { $0.timestamp }.sorted()
                if let earliestTimestamp = sortedTimestamps.first {
                    resetsAt = Date(timeIntervalSince1970: earliestTimestamp / 1000.0).addingTimeInterval(windowSeconds)
                }
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
                statusMessage: "Error reading Antigravity history: \(error.localizedDescription)",
                buckets: []
            )
        }
    }
}
