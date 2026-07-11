import Foundation
import OpenBurnBarCore

private struct Arguments {
    let samples: Int
    let warmups: Int
    let output: String

    static func parse(_ values: [String]) throws -> Arguments {
        var parsed: [String: String] = [:]
        var index = 0
        while index < values.count {
            guard index + 1 < values.count else { throw ProbeError("Missing value for \(values[index])") }
            parsed[values[index]] = values[index + 1]
            index += 2
        }
        guard let output = parsed["--output"],
              let samples = parsed["--samples"].flatMap(Int.init), samples >= 5,
              let warmups = parsed["--warmups"].flatMap(Int.init), warmups >= 0
        else { throw ProbeError("Expected --output, --samples >= 5, and --warmups >= 0") }
        return Arguments(samples: samples, warmups: warmups, output: output)
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Percentiles: Codable {
    let minimum: Double
    let p50: Double
    let p95: Double
    let p99: Double
    let maximum: Double
}

private struct Result: Codable {
    let id = "stream.first-visible-delta-decode"
    let unit = "milliseconds"
    let sampleCount: Int
    let percentiles: Percentiles
    let checksum: Int64
}

private let lines = [
    ": openburnbar keepalive",
    "event: message",
    #"data: {"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}"#,
    "",
    #"data: {"choices":[{"delta":{"reasoning_content":"checking"},"finish_reason":null}]}"#,
    "",
    #"data: {"choices":[{"delta":{"content":"Ready"},"finish_reason":null}]}"#,
    "",
    "data: [DONE]"
]

private func firstVisibleDelta() throws -> Int64 {
    var parser = HermesOpenAICompatibleStreamParser()
    for (index, line) in lines.enumerated() {
        let result = parser.events(fromSSELine: line)
        if result.streamedText {
            return Int64((index + 1) * 1_000 + result.events.count)
        }
    }
    throw ProbeError("Hermes parser did not emit a first visible stream delta")
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

private func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
    let position = quantile * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    guard lower != upper else { return sorted[lower] }
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
}

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    for _ in 0..<arguments.warmups { _ = try firstVisibleDelta() }
    var durations: [Double] = []
    var checksum: Int64 = 0
    for _ in 0..<arguments.samples {
        let start = ContinuousClock.now
        checksum &+= try firstVisibleDelta()
        durations.append(milliseconds(start.duration(to: .now)))
    }
    let sorted = durations.sorted()
    let result = Result(
        sampleCount: durations.count,
        percentiles: Percentiles(
            minimum: sorted[0],
            p50: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99),
            maximum: sorted[sorted.count - 1]
        ),
        checksum: checksum
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try (encoder.encode(result) + Data([0x0A])).write(
        to: URL(fileURLWithPath: arguments.output),
        options: .atomic
    )
} catch {
    FileHandle.standardError.write(Data("OpenBurnBarStreamPerfProbe: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
