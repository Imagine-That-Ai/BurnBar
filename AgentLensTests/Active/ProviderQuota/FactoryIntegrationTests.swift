import Foundation
import XCTest

/// Live integration test: verifies real droid session files exist on disk
/// with valid tokenUsage data. Proves Factory adapter has ground truth data.
@MainActor
final class FactoryIntegrationTests: XCTestCase {

    func test_droidSessionFiles_existWithRealTokenCounts() throws {
        let sessionsPath = ("~/.factory/sessions" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: sessionsPath) else {
            print("SKIP: ~/.factory/sessions not found — droid not installed")
            return
        }

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sessionsPath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            print("SKIP: Could not enumerate sessions")
            return
        }

        var filesScanned = 0
        var filesWithUsage = 0
        var totalInput: Int64 = 0
        var totalOutput: Int64 = 0
        var totalCacheRead: Int64 = 0
        var totalThinking: Int64 = 0
        var models: Set<String> = []

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "json",
                  fileURL.lastPathComponent.hasSuffix(".settings.json") else { continue }
            filesScanned += 1

            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = json["tokenUsage"] as? [String: Any] else { continue }

            let input = (usage["inputTokens"] as? Int64) ?? 0
            let output = (usage["outputTokens"] as? Int64) ?? 0
            let cacheRead = (usage["cacheReadTokens"] as? Int64) ?? 0
            let thinking = (usage["thinkingTokens"] as? Int64) ?? 0

            if input + output + cacheRead + thinking > 0 {
                filesWithUsage += 1
                totalInput += input
                totalOutput += output
                totalCacheRead += cacheRead
                totalThinking += thinking
                if let model = json["model"] as? String { models.insert(model) }
            }
        }

        XCTAssertGreaterThan(filesScanned, 0, "Must find droid session files on disk")
        XCTAssertGreaterThan(filesWithUsage, 0, "At least one session must have tokenUsage")
        XCTAssertGreaterThan(totalInput + totalOutput, 0, "Must have non-zero token counts")

        print("✅ FACTORY DROID: \(filesWithUsage)/\(filesScanned) files with usage")
        print("   Tokens: in=\(totalInput) out=\(totalOutput) cache=\(totalCacheRead) think=\(totalThinking)")
        if !models.isEmpty {
            print("   Models: \(models.sorted().joined(separator: ", "))")
        }
    }
}
