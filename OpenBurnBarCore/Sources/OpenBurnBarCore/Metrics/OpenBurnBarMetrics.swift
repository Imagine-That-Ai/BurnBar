import Foundation
import OSLog

// MARK: - OpenBurnBar Metrics

/// Structured metrics export for operational observability.
///
/// Emits parseable key=value lines to os_log so log aggregation pipelines
/// can extract metrics without a dedicated metrics server.
///
/// Usage:
/// ```swift
/// OpenBurnBarMetrics.histogram(name: "search_latency_ms", value: 45.2, labels: ["mode": "hybrid"])
/// OpenBurnBarMetrics.counter(name: "sync_success", labels: ["provider": "firebase"])
/// ```
public enum OpenBurnBarMetrics {
    private static let logger = Logger(subsystem: "com.openburnbar.metrics", category: "export")

    /// Emits a gauge metric (point-in-time value).
    public static func gauge(
        name: String,
        value: Double,
        labels: [String: String] = [:]
    ) {
        let labelStr = formatLabels(labels)
        logger.info("metric_type=gauge metric_name=\(name) metric_value=\(value, format: .fixed(precision: 4)) \(labelStr)")
    }

    /// Emits a histogram metric (sampled value for distribution analysis).
    public static func histogram(
        name: String,
        value: Double,
        labels: [String: String] = [:]
    ) {
        let labelStr = formatLabels(labels)
        logger.info("metric_type=histogram metric_name=\(name) metric_value=\(value, format: .fixed(precision: 4)) \(labelStr)")
    }

    /// Emits a counter metric (monotonically increasing value).
    public static func counter(
        name: String,
        delta: Double = 1,
        labels: [String: String] = [:]
    ) {
        let labelStr = formatLabels(labels)
        logger.info("metric_type=counter metric_name=\(name) metric_delta=\(delta, format: .fixed(precision: 4)) \(labelStr)")
    }

    private static func formatLabels(_ labels: [String: String]) -> String {
        guard !labels.isEmpty else { return "" }
        return labels.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ")
    }
}
