import Foundation
import OpenBurnBarCore

struct AntigravityQuotaAdapter: ProviderQuotaAdapter {

    // MARK: - Model Catalog

    struct ModelTier {
        let name: String
        let dailyCap: Double
    }

    static let availableModels: [ModelTier] = [
        ModelTier(name: "Gemini 3.5 Flash (High)", dailyCap: 1000),
        ModelTier(name: "Gemini 3.5 Flash (Medium)", dailyCap: 1500),
        ModelTier(name: "Gemini 3.1 Pro (High)", dailyCap: 250),
        ModelTier(name: "Gemini 3.1 Pro (Low)", dailyCap: 500),
        ModelTier(name: "Claude Sonnet 4.6 (Thinking)", dailyCap: 200),
        ModelTier(name: "Claude Opus 4.6 (Thinking)", dailyCap: 100),
        ModelTier(name: "GPT-OSS 120B (Medium)", dailyCap: 400),
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

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let historyURL = context.homeDirectoryURL.appendingPathComponent(".gemini/antigravity-cli/history.jsonl")
        let settingsURL = context.homeDirectoryURL.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        let now = Date()

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

            // --- Parse history events in rolling 24h window ---
            let data = try Data(contentsOf: historyURL)
            guard let contentString = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "AntigravityQuotaAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode history file as UTF-8"])
            }

            let lines = contentString.components(separatedBy: .newlines)
            let decoder = JSONDecoder()
            let cutoff = now.addingTimeInterval(-24 * 60 * 60)

            var eventsIn24h: [HistoryEvent] = []

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                guard let lineData = trimmed.data(using: .utf8),
                      let event = try? decoder.decode(HistoryEvent.self, from: lineData) else {
                    continue
                }

                let eventDate = Date(timeIntervalSince1970: event.timestamp / 1000.0)
                if eventDate >= cutoff && eventDate <= now {
                    eventsIn24h.append(event)
                }
            }

            let usedCount = Double(eventsIn24h.count)

            // --- Compute resetsAt from the earliest event in the 24h window ---
            var resetsAt: Date? = nil
            if !eventsIn24h.isEmpty {
                let sortedTimestamps = eventsIn24h.map { $0.timestamp }.sorted()
                if let earliestTimestamp = sortedTimestamps.first {
                    resetsAt = Date(timeIntervalSince1970: earliestTimestamp / 1000.0).addingTimeInterval(24 * 60 * 60)
                }
            }

            // --- Build per-model buckets ---
            var buckets: [ProviderQuotaBucket] = []

            // Active model bucket first.
            let activeModelTier = Self.availableModels.first(where: { $0.name == activeModelName })
            let activeCap = activeModelTier?.dailyCap ?? 100.0
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
                isEstimated: false
            )
            buckets.append(activeBucket)

            // Inactive model buckets — full headroom, no resetsAt.
            for model in Self.availableModels where model.name != activeModelName {
                let bucket = ProviderQuotaBucket(
                    key: "model_\(Self.snakeCaseKey(for: model.name))",
                    label: model.name,
                    windowKind: .rollingHours,
                    usedValue: 0,
                    limitValue: model.dailyCap,
                    remainingValue: model.dailyCap,
                    usedPercent: 0,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: false
                )
                buckets.append(bucket)
            }

            return ProviderQuotaSnapshot(
                provider: .antigravity,
                fetchedAt: now,
                source: .localCLI,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Active model: \(activeModelName). Rolling 24h quota across \(Self.availableModels.count) model tiers.",
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
