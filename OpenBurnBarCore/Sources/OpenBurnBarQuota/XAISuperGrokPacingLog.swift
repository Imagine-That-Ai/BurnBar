import Foundation

/// Shared SuperGrok pacing JSONL writer used by the Mac app and daemon gateway.
/// Consumer SuperGrok tiers have no official quota API; the adapter counts events
/// in this log over a rolling 2-hour window.
public enum XAISuperGrokPacingLog {
    public static let planTierDefaultsKey = "xaiQuotaPlanTier"

    private struct Event: Codable {
        let timestamp: Double
        let model: String?
        let plan: String?
        let source: String?
    }

    public static func logURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OpenBurnBar/xai/superGrok-events.jsonl", isDirectory: false)
    }

    private static func defaultHomeDirectoryURL(fileManager: FileManager = .default) -> URL {
        #if os(macOS)
        fileManager.homeDirectoryForCurrentUser
        #else
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #endif
    }

    /// Append one pacing event when the active xAI plan tier is a consumer SuperGrok tier.
    public static func recordPromptDispatched(
        model: String? = nil,
        source: String? = nil,
        at date: Date = Date(),
        homeDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        planTierRawValue: String? = UserDefaults.standard.string(forKey: planTierDefaultsKey)
    ) {
        guard let planTierRawValue,
              planTierRawValue.hasPrefix("superGrok") else {
            return
        }

        let resolvedHome = homeDirectoryURL ?? defaultHomeDirectoryURL(fileManager: fileManager)
        let url = logURL(homeDirectoryURL: resolvedHome)
        let event = Event(
            timestamp: date.timeIntervalSince1970 * 1000.0,
            model: model,
            plan: planTierRawValue,
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
                try line.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        } catch {
            // Best-effort estimator — ignore write failures.
        }
    }
}
