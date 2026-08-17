import Foundation
import XCTest
@testable import OpenBurnBarQuota

#if canImport(Darwin)
import Darwin
#endif

/// Opt-in, machine-local benchmark for Claude's real JSONL corpus.
///
/// The normal test suite skips this class. Run it with:
///
/// `OPENBURNBAR_CLAUDE_REAL_CORPUS_BENCHMARK=1`
/// `OPENBURNBAR_CLAUDE_REAL_CORPUS_BENCHMARK_OUTPUT=/private/path`
///
/// The report contains only counts, byte totals, timings, and process
/// footprint. It never records transcript text or per-session token totals.
final class ClaudeJSONLRealCorpusBenchmarkTests: XCTestCase {
    func testColdRestartAndWarmScans() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENBURNBAR_CLAUDE_REAL_CORPUS_BENCHMARK"] == "1" else {
            throw XCTSkip("real Claude corpus benchmark is opt-in")
        }
        let outputPath = try XCTUnwrap(
            environment["OPENBURNBAR_CLAUDE_REAL_CORPUS_BENCHMARK_OUTPUT"],
            "set an explicit private output directory"
        )
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let cacheURL = outputDirectory.appendingPathComponent("claude-jsonl-quota-cache.plist")
        let reportURL = outputDirectory.appendingPathComponent("benchmark.json")
        XCTAssertFalse(fileManager.fileExists(atPath: cacheURL.path), "benchmark output must start cold")
        XCTAssertFalse(fileManager.fileExists(atPath: reportURL.path), "refusing to overwrite benchmark evidence")

        let home = fileManager.homeDirectoryForCurrentUser
        let now = Date()
        ClaudeQuotaAdapter.resetJSONLQuotaCacheMemoryForTesting(cacheURL: cacheURL)

        let footprintBefore = currentPhysicalFootprint()
        let cold = try measure {
            try ClaudeQuotaAdapter.scanJSONLTokenWindows(
                homeDirectoryURL: home,
                fileManager: fileManager,
                environment: [:],
                now: now,
                cacheURL: cacheURL
            )
        }
        let footprintAfterCold = currentPhysicalFootprint()

        ClaudeQuotaAdapter.resetJSONLQuotaCacheMemoryForTesting(cacheURL: cacheURL)
        let restarted = try measure {
            try ClaudeQuotaAdapter.scanJSONLTokenWindows(
                homeDirectoryURL: home,
                fileManager: fileManager,
                environment: [:],
                now: now,
                cacheURL: cacheURL
            )
        }
        let footprintAfterRestart = currentPhysicalFootprint()

        let warm = try measure {
            try ClaudeQuotaAdapter.scanJSONLTokenWindows(
                homeDirectoryURL: home,
                fileManager: fileManager,
                environment: [:],
                now: now,
                cacheURL: cacheURL
            )
        }
        let footprintAfterWarm = currentPhysicalFootprint()

        XCTAssertGreaterThan(cold.value.filesScanned, 0)
        XCTAssertGreaterThan(cold.value.bytesRead, 0)
        let liveAppendBudget = max(cold.value.bytesRead / 100, 1 * 1024 * 1024)
        XCTAssertLessThan(
            restarted.value.bytesRead,
            liveAppendBudget,
            "a fresh process must restore unchanged facts from disk and read only bounded live appends"
        )
        XCTAssertLessThan(
            warm.value.bytesRead,
            liveAppendBudget,
            "same-process refresh must read only bounded live appends"
        )
        XCTAssertEqual(cold.value.fiveHourTokens, restarted.value.fiveHourTokens)
        XCTAssertEqual(cold.value.sevenDayTokens, restarted.value.sevenDayTokens)
        XCTAssertEqual(cold.value.fiveHourTokens, warm.value.fiveHourTokens)
        XCTAssertEqual(cold.value.sevenDayTokens, warm.value.sevenDayTokens)

        let cacheBytes = (try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let report: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "filesScanned": cold.value.filesScanned,
            "cold": [
                "durationMilliseconds": cold.durationMilliseconds,
                "bytesRead": cold.value.bytesRead,
                "physicalFootprintBeforeBytes": footprintBefore,
                "physicalFootprintAfterBytes": footprintAfterCold
            ],
            "restart": [
                "durationMilliseconds": restarted.durationMilliseconds,
                "bytesRead": restarted.value.bytesRead,
                "physicalFootprintAfterBytes": footprintAfterRestart
            ],
            "sameProcessWarm": [
                "durationMilliseconds": warm.durationMilliseconds,
                "bytesRead": warm.value.bytesRead,
                "physicalFootprintAfterBytes": footprintAfterWarm
            ],
            "factsCacheBytes": cacheBytes
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: reportURL, options: [.atomic])
    }

    private func measure<T>(_ work: () throws -> T) rethrows -> (value: T, durationMilliseconds: Double) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let value = try work()
        let endedAt = DispatchTime.now().uptimeNanoseconds
        return (value, Double(endedAt - startedAt) / 1_000_000)
    }

    private func currentPhysicalFootprint() -> Int64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
        #else
        return 0
        #endif
    }
}
