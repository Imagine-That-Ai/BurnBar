import Foundation

/// Anti-fingerprinting bucketing. Raw counts/durations/amounts are never sent;
/// they map to coarse, canonical buckets identical on every platform. Boundaries
/// are the single source mirrored in docs/analytics/event-taxonomy.md.
enum AnalyticsBuckets {

    static func durationMs(_ ms: Int) -> String {
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

    static func durationMs(_ ms: Double) -> String { durationMs(Int(ms.rounded())) }

    static func count(_ n: Int) -> String {
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

    static func amountUSD(_ usd: Double) -> String {
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

    static func percent(_ p: Double) -> String {
        switch p {
        case ..<10: return "0-10"
        case ..<25: return "10-25"
        case ..<50: return "25-50"
        case ..<75: return "50-75"
        case ..<90: return "75-90"
        default: return "90-100"
        }
    }

    static func sizeBytes(_ b: Int) -> String {
        switch b {
        case ..<1_000: return "<1KB"
        case ..<100_000: return "1-100KB"
        case ..<1_000_000: return "100KB-1MB"
        case ..<10_000_000: return "1-10MB"
        case ..<100_000_000: return "10-100MB"
        default: return ">100MB"
        }
    }

    static func durationSeconds(_ s: Double) -> String {
        switch s {
        case ..<5: return "<5s"
        case ..<30: return "5-30s"
        case ..<120: return "30s-2m"
        case ..<600: return "2-10m"
        case ..<3_600: return "10-60m"
        default: return ">60m"
        }
    }

    static func toolName(_ name: String?) -> String {
        guard let name else { return "unknown" }
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !normalized.isEmpty else { return "unknown" }

        switch normalized {
        case "read", "view", "view_file", "open_file":
            return "file_read"
        case "write", "create_file":
            return "file_write"
        case "edit", "editfile", "edit_file", "apply_patch":
            return "file_edit"
        case "bash", "shell", "shell_run", "exec", "exec_command", "terminal":
            return "terminal"
        case "grep", "grep_search", "search", "rg", "ripgrep":
            return "search"
        case "web", "webfetch", "web_fetch", "websearch", "web_search":
            return "web"
        case "memory", "memory_read", "memory_write":
            return "memory"
        case "browser", "browser_screenshot", "browser_click", "browser_open":
            return "browser"
        case "clipboard", "clipboard_read", "clipboard_write":
            return "clipboard"
        case "todo", "todo_read", "todo_write":
            return "todo"
        default:
            return "other"
        }
    }
}
