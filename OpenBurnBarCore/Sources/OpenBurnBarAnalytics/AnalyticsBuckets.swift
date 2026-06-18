import Foundation

/// Anti-fingerprinting bucketing. Raw counts/durations/amounts are never sent;
/// they map to coarse, canonical buckets identical on every platform. Boundaries
/// are the single source mirrored in docs/analytics/event-taxonomy.md and are
/// **byte-identical** to the macOS `AnalyticsBuckets` (the cross-platform funnel
/// only reads if a `500ms-1s` here equals a `500ms-1s` on macOS/web).
public enum AnalyticsBuckets {

    public static func durationMs(_ ms: Int) -> String {
        switch ms {
        case ..<100: return "<100ms"
        case ..<500: return "100-500ms"
        case ..<1_000: return "500ms-1s"
        case ..<3_000: return "1-3s"
        case ..<10_000: return "3-10s"
        case ..<30_000: return "10-30s"
        default: return ">30s"
        }
    }

    public static func durationMs(_ ms: Double) -> String { durationMs(Int(ms.rounded())) }

    public static func count(_ n: Int) -> String {
        switch n {
        case ..<1: return "0"        // 0 and negatives clamp to "0"
        case 1: return "1"
        case 2...5: return "2-5"
        case 6...20: return "6-20"
        case 21...100: return "21-100"
        case 101...500: return "101-500"
        default: return ">500"
        }
    }

    public static func amountUSD(_ usd: Double) -> String {
        switch usd {
        case ...0: return "0"
        case ..<1: return "<1"
        case ..<10: return "1-10"
        case ..<50: return "10-50"
        case ..<100: return "50-100"
        case ..<500: return "100-500"
        default: return ">500"
        }
    }

    public static func percent(_ p: Double) -> String {
        switch p {
        case ..<10: return "0-10"
        case ..<25: return "10-25"
        case ..<50: return "25-50"
        case ..<75: return "50-75"
        case ..<90: return "75-90"
        default: return "90-100"
        }
    }

    public static func sizeBytes(_ b: Int) -> String {
        switch b {
        case ..<1_000: return "<1KB"
        case ..<100_000: return "1-100KB"
        case ..<1_000_000: return "100KB-1MB"
        case ..<10_000_000: return "1-10MB"
        case ..<100_000_000: return "10-100MB"
        default: return ">100MB"
        }
    }

    public static func durationSeconds(_ s: Double) -> String {
        switch s {
        case ..<5: return "<5s"
        case ..<30: return "5-30s"
        case ..<120: return "30s-2m"
        case ..<600: return "2-10m"
        case ..<3_600: return "10-60m"
        default: return ">60m"
        }
    }
}
