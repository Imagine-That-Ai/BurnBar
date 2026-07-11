import Foundation
import GRDB

#if os(macOS)
import Darwin
import MachO
#elseif os(Linux)
import Glibc
#endif

private struct Arguments {
    var output: String?
    var rows = 10_000
    var samples = 30
    var warmups = 5
    var soakSeconds = 30
    var seed = 20_260_709

    static func parse(_ values: [String]) throws -> Arguments {
        var result = Arguments()
        var index = 0
        while index < values.count {
            let key = values[index]
            guard index + 1 < values.count else {
                throw ProbeError.invalidArgument("Missing value for \(key)")
            }
            let value = values[index + 1]
            switch key {
            case "--output": result.output = value
            case "--rows": result.rows = try positiveInt(value, key: key)
            case "--samples": result.samples = try positiveInt(value, key: key)
            case "--warmups": result.warmups = try nonnegativeInt(value, key: key)
            case "--soak-seconds": result.soakSeconds = try nonnegativeInt(value, key: key)
            case "--seed": result.seed = try nonnegativeInt(value, key: key)
            default: throw ProbeError.invalidArgument("Unknown argument \(key)")
            }
            index += 2
        }
        guard result.rows >= 100 else { throw ProbeError.invalidArgument("--rows must be at least 100") }
        guard result.samples >= 5 else { throw ProbeError.invalidArgument("--samples must be at least 5") }
        return result
    }

    private static func positiveInt(_ value: String, key: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw ProbeError.invalidArgument("\(key) must be a positive integer")
        }
        return parsed
    }

    private static func nonnegativeInt(_ value: String, key: String) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else {
            throw ProbeError.invalidArgument("\(key) must be a nonnegative integer")
        }
        return parsed
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invariant(String)

    var description: String {
        switch self {
        case .invalidArgument(let message), .invariant(let message): message
        }
    }
}

private struct Percentiles: Codable {
    let minimum: Double
    let p50: Double
    let p95: Double
    let p99: Double
    let maximum: Double
}

private struct WorkloadResult: Codable {
    let id: String
    let unit: String
    let sampleCount: Int
    let percentiles: Percentiles
    let checksum: Int64
}

private struct ResourceSample: Codable {
    let elapsedSeconds: Double
    let rssBytes: UInt64
    let cpuSeconds: Double
}

private struct SoakResult: Codable {
    let requestedSeconds: Int
    let elapsedSeconds: Double
    let iterations: Int
    let samples: [ResourceSample]
    let rssStartBytes: UInt64
    let rssEndBytes: UInt64
    let rssMaximumBytes: UInt64
    let rssGrowthBytes: Int64
    let cpuUtilizationPercent: Double
}

private struct Host: Codable {
    let platform: String
    let architecture: String
    let operatingSystemVersion: String
    let processorCount: Int
}

private struct Report: Codable {
    let schemaVersion: Int
    let protocolVersion: String
    let generatedAt: String
    let host: Host
    let configuration: Configuration
    let workloads: [WorkloadResult]
    let soak: SoakResult
    let pass: Bool

    struct Configuration: Codable {
        let rows: Int
        let samples: Int
        let warmups: Int
        let soakSeconds: Int
        let seed: Int
    }
}

private struct Event: Codable {
    let type: String
    let sequence: Int
    let provider: String
    let project: String
    let content: String
    let inputTokens: Int
    let outputTokens: Int
}

private final class WorkloadHarness {
    private let database: DatabaseQueue
    private let jsonl: Data
    private let rows: Int

    init(rows: Int, seed: Int, directory: URL) throws {
        self.rows = rows
        database = try DatabaseQueue(path: directory.appendingPathComponent("matched-perf.sqlite").path)
        jsonl = try Self.makeJSONL(rows: rows, seed: seed)
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        try seedDatabase(seed: seed)
    }

    func databaseRangeQuery() throws -> Int64 {
        try database.read { db in
            let value = try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(inputTokens + outputTokens), 0)
                    FROM usage_rows
                    WHERE provider = ? AND timestamp >= ? AND timestamp < ?
                    """,
                arguments: ["codex", 1_700_000_000.0, 1_800_000_000.0]
            )
            return value ?? 0
        }
    }

    func memoryFTSSearch() throws -> Int64 {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid
                    FROM memory_fts
                    WHERE memory_fts MATCH ?
                    ORDER BY bm25(memory_fts)
                    LIMIT 50
                    """,
                arguments: ["recovery AND daemon"]
            )
            return rows.reduce(0) { partial, row in
                partial &+ (row["rowid"] as Int64)
            }
        }
    }

    func incrementalJSONLDecode() throws -> Int64 {
        var checksum: Int64 = 0
        let decoder = JSONDecoder()
        for line in jsonl.split(separator: 0x0A) where !line.isEmpty {
            let event = try decoder.decode(Event.self, from: Data(line))
            checksum &+= Int64(event.sequence + event.inputTokens + event.outputTokens)
        }
        return checksum
    }

    private func seedDatabase(seed: Int) throws {
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE usage_rows (
                    id INTEGER PRIMARY KEY,
                    provider TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    inputTokens INTEGER NOT NULL,
                    outputTokens INTEGER NOT NULL,
                    project TEXT NOT NULL
                );
                CREATE INDEX usage_provider_time_idx ON usage_rows(provider, timestamp);
                CREATE VIRTUAL TABLE memory_fts USING fts5(content, project, provider, tokenize='porter unicode61');
                """)
            let usage = try db.makeStatement(
                sql: "INSERT INTO usage_rows(id, provider, timestamp, inputTokens, outputTokens, project) VALUES (?, ?, ?, ?, ?, ?)"
            )
            let memory = try db.makeStatement(
                sql: "INSERT INTO memory_fts(rowid, content, project, provider) VALUES (?, ?, ?, ?)"
            )
            for index in 0..<rows {
                let provider = index.isMultiple(of: 3) ? "codex" : index.isMultiple(of: 2) ? "claude" : "factory"
                let project = "project-\((index + seed) % 97)"
                try usage.execute(arguments: [
                    index + 1,
                    provider,
                    1_700_000_000.0 + Double(index % 20_000_000),
                    500 + ((index * 17 + seed) % 8_000),
                    100 + ((index * 11 + seed) % 4_000),
                    project
                ])
                let content = index.isMultiple(of: 7)
                    ? "daemon recovery restart socket health project memory \(index)"
                    : "provider session transcript quota routing project memory \(index)"
                try memory.execute(arguments: [index + 1, content, project, provider])
            }
        }
        let count = try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_rows") ?? 0 }
        guard count == rows else { throw ProbeError.invariant("Seeded \(count) rows, expected \(rows)") }
    }

    private static func makeJSONL(rows: Int, seed: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for index in 0..<rows {
            let event = Event(
                type: index.isMultiple(of: 9) ? "assistant.done" : "assistant.delta",
                sequence: index,
                provider: index.isMultiple(of: 2) ? "codex" : "claude",
                project: "project-\((index + seed) % 97)",
                content: "Incremental provider transcript event \(index) with stable payload.",
                inputTokens: 100 + ((index * 7 + seed) % 2_000),
                outputTokens: 20 + ((index * 5 + seed) % 1_000)
            )
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        return data
    }
}

private func benchmark(
    id: String,
    warmups: Int,
    samples: Int,
    operation: () throws -> Int64
) throws -> WorkloadResult {
    for _ in 0..<warmups { _ = try operation() }
    var durations: [Double] = []
    var checksum: Int64 = 0
    durations.reserveCapacity(samples)
    for _ in 0..<samples {
        let start = ContinuousClock.now
        checksum &+= try operation()
        durations.append(milliseconds(start.duration(to: .now)))
    }
    return WorkloadResult(
        id: id,
        unit: "milliseconds",
        sampleCount: durations.count,
        percentiles: summarize(durations),
        checksum: checksum
    )
}

private func runSoak(harness: WorkloadHarness, seconds: Int) throws -> SoakResult {
    let started = ContinuousClock.now
    let startedCPU = processCPUSeconds()
    let deadline = started.advanced(by: .seconds(seconds))
    var samples: [ResourceSample] = []
    var iterations = 0
    var nextSample = started
    repeat {
        _ = try harness.databaseRangeQuery()
        _ = try harness.memoryFTSSearch()
        _ = try harness.incrementalJSONLDecode()
        iterations += 1
        let now = ContinuousClock.now
        if now >= nextSample {
            samples.append(ResourceSample(
                elapsedSeconds: milliseconds(started.duration(to: now)) / 1_000,
                rssBytes: residentSetBytes(),
                cpuSeconds: processCPUSeconds() - startedCPU
            ))
            nextSample = now.advanced(by: .seconds(1))
        }
    } while ContinuousClock.now < deadline || iterations == 0

    let ended = ContinuousClock.now
    samples.append(ResourceSample(
        elapsedSeconds: milliseconds(started.duration(to: ended)) / 1_000,
        rssBytes: residentSetBytes(),
        cpuSeconds: processCPUSeconds() - startedCPU
    ))
    let rssStart = samples.first?.rssBytes ?? 0
    let rssEnd = samples.last?.rssBytes ?? 0
    let rssMaximum = samples.map(\.rssBytes).max() ?? 0
    let elapsedSeconds = max(milliseconds(started.duration(to: ended)) / 1_000, 0.001)
    let cpuSeconds = max(processCPUSeconds() - startedCPU, 0)
    return SoakResult(
        requestedSeconds: seconds,
        elapsedSeconds: elapsedSeconds,
        iterations: iterations,
        samples: samples,
        rssStartBytes: rssStart,
        rssEndBytes: rssEnd,
        rssMaximumBytes: rssMaximum,
        rssGrowthBytes: Int64(rssEnd) - Int64(rssStart),
        cpuUtilizationPercent: cpuSeconds / elapsedSeconds * 100
    )
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

private func summarize(_ values: [Double]) -> Percentiles {
    let sorted = values.sorted()
    return Percentiles(
        minimum: sorted.first ?? 0,
        p50: percentile(sorted, 0.50),
        p95: percentile(sorted, 0.95),
        p99: percentile(sorted, 0.99),
        maximum: sorted.last ?? 0
    )
}

private func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let position = quantile * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    if lower == upper { return sorted[lower] }
    let fraction = position - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
}

private func processCPUSeconds() -> Double {
    Double(clock()) / Double(CLOCKS_PER_SEC)
}

private func residentSetBytes() -> UInt64 {
    #if os(macOS)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    #elseif os(Linux)
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
          let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmRSS:") }),
          let kibibytes = UInt64(line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first ?? "")
    else { return 0 }
    return kibibytes * 1_024
    #else
    return 0
    #endif
}

private func platformName() -> String {
    #if os(macOS)
    return "macos"
    #elseif os(Linux)
    return "linux"
    #else
    return "unknown"
    #endif
}

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("openburnbar-matched-perf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let harness = try WorkloadHarness(rows: arguments.rows, seed: arguments.seed, directory: directory)
    let workloads = try [
        benchmark(id: "sqlite.range-query", warmups: arguments.warmups, samples: arguments.samples) {
            try harness.databaseRangeQuery()
        },
        benchmark(id: "sqlite.fts-memory-search", warmups: arguments.warmups, samples: arguments.samples) {
            try harness.memoryFTSSearch()
        },
        benchmark(id: "jsonl.incremental-decode", warmups: arguments.warmups, samples: arguments.samples) {
            try harness.incrementalJSONLDecode()
        }
    ]
    let soak = try runSoak(harness: harness, seconds: arguments.soakSeconds)
    let report = Report(
        schemaVersion: 1,
        protocolVersion: "openburnbar-matched-workload-v1",
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        host: Host(
            platform: platformName(),
            architecture: ProcessInfo.processInfo.machineHardwareName,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.activeProcessorCount
        ),
        configuration: .init(
            rows: arguments.rows,
            samples: arguments.samples,
            warmups: arguments.warmups,
            soakSeconds: arguments.soakSeconds,
            seed: arguments.seed
        ),
        workloads: workloads,
        soak: soak,
        pass: workloads.allSatisfy { $0.sampleCount == arguments.samples && $0.checksum != 0 }
            && soak.iterations > 0
            && soak.rssStartBytes > 0
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report) + Data([0x0A])
    if let output = arguments.output {
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
    }
    exit(report.pass ? EXIT_SUCCESS : EXIT_FAILURE)
} catch {
    FileHandle.standardError.write(Data("OpenBurnBarPerfProbe: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var system = utsname()
        uname(&system)
        var machine = system.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
