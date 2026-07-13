import Foundation
import OpenBurnBarKernel

public struct OMPQuotaAdapter: ProviderQuotaAdapter {
    public init() {}

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        #if !os(macOS)
        return unavailable(message: "OMP quota requires macOS CLI resolution.")
        #else
        guard let executableURL = CLILaunchAdapter.resolveExecutable(for: .omp) else {
            return unavailable(message: "OMP CLI was not found. Install Oh My Pi and ensure `omp` is on your PATH.")
        }
        let executable = executableURL.path
        var env = CLILaunchAdapter.buildAllowlistedBaselineEnvironment(baseEnv: context.environment)
        env["PATH"] = CLILaunchAdapter.trustedExecutableEnvironmentPath(homeDirectory: context.homeDirectoryURL.path)
        env["PWD"] = context.homeDirectoryURL.path

        do {
            let data = try Self.runUsageJSON(
                executable: executable,
                context: context,
                environment: env
            )
            let payload = try JSONDecoder().decode(OMPUsagePayload.self, from: data)
            let buckets = payload.reports.flatMap(Self.buckets(from:))
            guard !buckets.isEmpty else {
                return ProviderQuotaSnapshot(
                    provider: .omp,
                    fetchedAt: payload.generatedDate ?? Date(),
                    source: .localCLI,
                    confidence: .unavailable,
                    managementURL: nil,
                    statusMessage: "OMP returned no displayable usage limits from `omp usage --json --redact`.",
                    buckets: []
                )
            }
            return ProviderQuotaSnapshot(
                provider: .omp,
                fetchedAt: payload.generatedDate ?? Date(),
                source: .localCLI,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "OMP usage refreshed from `omp usage --json --redact`.",
                buckets: buckets
            )
        } catch {
            return unavailable(message: "OMP usage could not be read from `omp usage --json --redact`: \(error.localizedDescription)")
        }
        #endif
    }

    private func unavailable(message: String) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: .omp,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: message,
            buckets: []
        )
    }

    private static func runUsageJSON(
        executable: String,
        context: ProviderQuotaAdapterContext,
        environment: [String: String]
    ) throws -> Data {
        return try context.cliExecutor.run(
            executable: executable,
            arguments: ["usage", "--json", "--redact"],
            environment: environment
        )
    }

    private static func buckets(from report: OMPUsageReport) -> [ProviderQuotaBucket] {
        report.limits.compactMap { limit in
            let labelPrefix = Self.providerLabel(report.provider)
            let label = labelPrefix.isEmpty ? limit.label : "\(labelPrefix) · \(limit.label)"
            let usedPercent = limit.amount.usedFraction.map { min(max($0 * 100, 0), 100) }
                ?? percent(used: limit.amount.used, limit: limit.amount.limit)
            let remainingValue = limit.amount.remaining
                ?? remaining(from: limit.amount.limit, used: limit.amount.used)
            let providerKey = FlexibleQuotaBucketNormalizer.sanitizeKey(report.provider)
            let limitKey = FlexibleQuotaBucketNormalizer.sanitizeKey(limit.id)
            let bucketKey = providerKey.isEmpty ? "omp-\(limitKey)" : "omp-\(providerKey)-\(limitKey)"
            return ProviderQuotaBucket(
                key: bucketKey,
                label: label,
                windowKind: windowKind(for: limit.window),
                usedValue: limit.amount.used,
                limitValue: limit.amount.limit,
                remainingValue: remainingValue,
                usedPercent: usedPercent,
                resetsAt: limit.window.resetsDate,
                unit: unit(for: limit.amount.unit),
                isEstimated: false
            )
        }
    }

    private static func providerLabel(_ provider: String) -> String {
        switch provider.lowercased() {
        case "openai-codex": return "Codex"
        case "anthropic": return "Claude"
        case "ollama-cloud": return "Ollama Cloud"
        case "zai": return "Z.ai"
        default:
            return provider
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func unit(for rawUnit: String?) -> ProviderQuotaUnit {
        switch rawUnit?.lowercased() {
        case "requests", "request": return .requests
        case "tokens", "token": return .tokens
        case "sessions", "session": return .sessions
        case "count", "credits", "credit": return .count
        default: return .percent
        }
    }

    private static func windowKind(for window: OMPUsageWindow) -> ProviderQuotaWindowKind {
        let id = window.id.lowercased()
        if id == "1w" || id.contains("week") { return .weekly }
        if id == "1mo" || id.contains("month") || id == "30d" { return .monthly }
        if id.hasSuffix("h") { return .rollingHours }
        if id.hasSuffix("d") { return .rollingDays }
        if let duration = window.durationMs {
            if duration <= 6 * 60 * 60 * 1_000 { return .rollingHours }
            if duration <= 8 * 24 * 60 * 60 * 1_000 { return .rollingDays }
            if duration <= 32 * 24 * 60 * 60 * 1_000 { return .monthly }
        }
        return .custom
    }

    private static func percent(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return min(max(used / limit * 100, 0), 100)
    }

    private static func remaining(from limit: Double?, used: Double?) -> Double? {
        guard let limit, let used else { return nil }
        return max(limit - used, 0)
    }
}

private struct OMPUsagePayload: Decodable {
    let generatedAt: Double?
    let reports: [OMPUsageReport]

    var generatedDate: Date? {
        generatedAt.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}

private struct OMPUsageReport: Decodable {
    let provider: String
    let limits: [OMPUsageLimit]
}

private struct OMPUsageLimit: Decodable {
    let id: String
    let label: String
    let window: OMPUsageWindow
    let amount: OMPUsageAmount
}

private struct OMPUsageWindow: Decodable {
    let id: String
    let durationMs: Double?
    let resetsAt: Double?

    var resetsDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}

private struct OMPUsageAmount: Decodable {
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let usedFraction: Double?
    let remainingFraction: Double?
    let unit: String?
}

private enum OMPUsageError: LocalizedError {
    case processExit(Int, String)

    var errorDescription: String? {
        switch self {
        case .processExit(let code, let stderr):
            let suffix = stderr.isEmpty ? "" : ": \(stderr)"
            return "omp usage exited with code \(code)\(suffix)"
        }
    }
}
