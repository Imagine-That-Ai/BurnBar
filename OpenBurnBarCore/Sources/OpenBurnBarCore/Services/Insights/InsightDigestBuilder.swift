import Foundation
import CryptoKit

/// Builds the privacy-bounded `InsightDigest` that gets shipped to a model.
///
/// **Privacy contract** (also enforced by `InsightDigestPrivacyTests`):
///
///   • Device names hashed to `device_xxxx` (stable across builds).
///   • Project names hashed to `project_xxxx` for export. A user-visible
///     mapping is returned as `displayName` (last path component, only).
///   • Encoded payload is trimmed to 24 KB by dropping long-tail entries
///     (per-day per-provider extras, low-rank providers/models/projects).
///   • No keyFiles or full message text ever appears.
///   • Quota credentials/tokens never appear — only bucket metadata.
public struct InsightDigestBuilder: Sendable {
    public var taxonomy: InsightTaxonomy
    public var calendar: Calendar
    public var maxProviders: Int
    public var maxModels: Int
    public var maxProjects: Int
    public var maxDevices: Int
    public var maxDailyPoints: Int
    public var maxActions: Int
    public var maxSummaryRuns: Int
    public var maxAnomalies: Int

    public init(taxonomy: InsightTaxonomy = .default,
                calendar: Calendar = .current,
                maxProviders: Int = 8,
                maxModels: Int = 12,
                maxProjects: Int = 8,
                maxDevices: Int = 4,
                maxDailyPoints: Int = 30,
                maxActions: Int = 50,
                maxSummaryRuns: Int = 25,
                maxAnomalies: Int = 12) {
        self.taxonomy = taxonomy
        self.calendar = calendar
        self.maxProviders = maxProviders
        self.maxModels = maxModels
        self.maxProjects = maxProjects
        self.maxDevices = maxDevices
        self.maxDailyPoints = maxDailyPoints
        self.maxActions = maxActions
        self.maxSummaryRuns = maxSummaryRuns
        self.maxAnomalies = maxAnomalies
    }

    /// Build a digest. May trim itself further to stay within the
    /// `InsightDigest.maxEncodedBytes` ceiling.
    public func build(from snapshot: InsightDataSnapshot,
                      filter: InsightFilter) throws -> InsightDigest {
        // 1. Apply the filter on top of the window.
        let usages = filtered(usages: snapshot.usages, filter: filter)
        let sessions = filtered(sessions: snapshot.sessions, filter: filter)

        // 2. Roll up totals.
        let totals = InsightDigest.Totals(
            costUSD: usages.reduce(0) { $0 + $1.costUSD },
            totalTokens: usages.reduce(0) { $0 + $1.totalTokens },
            inputTokens: usages.reduce(0) { $0 + $1.inputTokens },
            outputTokens: usages.reduce(0) { $0 + $1.outputTokens },
            reasoningTokens: usages.reduce(0) { $0 + $1.reasoningTokens },
            cacheReadTokens: usages.reduce(0) { $0 + $1.cacheReadTokens },
            cacheCreationTokens: usages.reduce(0) { $0 + $1.cacheCreationTokens },
            sessionCount: Set(usages.map { "\($0.provider)|\($0.sessionID)" }).count
        )

        // 3. Provider / model / project / device snapshots.
        let providers = makeProviderSnapshots(usages: usages, sessions: sessions, limit: maxProviders)
        let models = makeModelSnapshots(usages: usages, sessions: sessions, limit: maxModels)
        let projects = makeProjectSnapshots(usages: usages, limit: maxProjects)
        let devices = makeDeviceSnapshots(usages: usages, limit: maxDevices)

        // 4. Time-series.
        let daily = makeDailyPoints(usages: usages, limit: maxDailyPoints)
        let hourly = makeHourlyBuckets(usages: usages)

        // 5. Use cases / focus signals.
        let useCases = makeUseCaseHistogram(sessions: sessions, usages: usages)
        let agentFocuses = makeAgentFocusSignals(sessions: sessions)
        let modelFocuses = makeModelFocusSignals(sessions: sessions, usages: usages)

        // 6. Quota snapshots.
        let quotas = snapshot.quotaBuckets.map {
            InsightDigest.QuotaSnapshotSummary(
                providerID: $0.providerKey,
                bucketName: $0.bucketName,
                used: $0.used,
                limit: $0.limit,
                resetsAt: $0.resetsAt
            )
        }

        // 7. Operating actions / summary runs.
        let actions = makeActionDigests(actions: snapshot.operatingActions, limit: maxActions)
        let summaryRuns = makeSummaryRunDigests(runs: snapshot.summaryRuns, limit: maxSummaryRuns)

        // 8. Precompute anomalies.
        let anomalies = makeAnomalies(daily: daily, limit: maxAnomalies)

        // 9. Assemble + compute content hash.
        var digest = InsightDigest(
            contentHash: "",
            generatedAt: snapshot.generatedAt,
            window: snapshot.window,
            rowCount: usages.count,
            totals: totals,
            providers: providers,
            models: models,
            projects: projects,
            devices: devices,
            daily: daily,
            hourly: hourly,
            useCaseHistogram: useCases,
            agentFocusSignals: agentFocuses,
            modelFocusSignals: modelFocuses,
            quotaSnapshots: quotas,
            operatingActions: actions,
            summaryRunsLog: summaryRuns,
            anomalies: anomalies,
            glossary: taxonomy
        )
        digest.contentHash = Self.computeContentHash(digest: digest)

        // 10. Enforce the 24 KB ceiling.
        digest = try trim(digest, toMaxBytes: InsightDigest.maxEncodedBytes)
        return digest
    }

    // MARK: - Stable content hash

    public static func computeContentHash(digest: InsightDigest) -> String {
        var withoutHash = digest
        withoutHash.contentHash = ""
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(withoutHash) else { return "" }
        let bytes = SHA256.hash(data: data)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Filtering

    private func filtered(usages: [InsightUsageRow], filter: InsightFilter) -> [InsightUsageRow] {
        usages.filter { row in
            if !filter.providers.isEmpty, !filter.providers.contains(row.provider) { return false }
            if !filter.models.isEmpty, !filter.models.contains(row.model) { return false }
            if !filter.projects.isEmpty {
                guard let p = row.projectName, filter.projects.contains(p) else { return false }
            }
            if let minC = filter.minCostUSD, row.costUSD < minC { return false }
            if let maxC = filter.maxCostUSD, row.costUSD > maxC { return false }
            return true
        }
    }

    private func filtered(sessions: [InsightSessionRow], filter: InsightFilter) -> [InsightSessionRow] {
        sessions.filter { row in
            if !filter.providers.isEmpty, !filter.providers.contains(row.provider) { return false }
            if !filter.projects.isEmpty {
                guard let p = row.projectName, filter.projects.contains(p) else { return false }
            }
            return true
        }
    }

    // MARK: - Snapshots

    private func makeProviderSnapshots(usages: [InsightUsageRow],
                                       sessions: [InsightSessionRow],
                                       limit: Int) -> [InsightDigest.ProviderSnapshot] {
        var perProvider: [String: (cost: Double, tokens: Int, sessions: Set<String>,
                                   topModels: [String: Int], titles: [String: Int],
                                   tools: [String: Int])] = [:]
        for u in usages {
            var entry = perProvider[u.provider] ?? (0, 0, [], [:], [:], [:])
            entry.cost += u.costUSD
            entry.tokens += u.totalTokens
            entry.sessions.insert(u.sessionID)
            entry.topModels[u.model, default: 0] += u.totalTokens
            perProvider[u.provider] = entry
        }
        for s in sessions {
            if let title = s.inferredTaskTitle, !title.isEmpty {
                var entry = perProvider[s.provider] ?? (0, 0, [], [:], [:], [:])
                entry.titles[title, default: 0] += 1
                for tool in s.keyTools { entry.tools[tool, default: 0] += 1 }
                perProvider[s.provider] = entry
            }
        }
        return perProvider
            .sorted {
                $0.value.cost != $1.value.cost ? $0.value.cost > $1.value.cost : $0.key < $1.key
            }
            .prefix(limit)
            .map { key, value in
                let topModels = Array(value.topModels
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(3).map(\.key))
                let topTitles = Array(value.titles
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(5).map(\.key))
                let topTools = Array(value.tools
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(5).map(\.key))
                return InsightDigest.ProviderSnapshot(
                    id: key,
                    displayName: key,
                    costUSD: value.cost,
                    totalTokens: value.tokens,
                    sessionCount: value.sessions.count,
                    topModels: topModels,
                    topInferredTaskTitles: topTitles,
                    topKeyTools: topTools
                )
            }
    }

    private func makeModelSnapshots(usages: [InsightUsageRow],
                                    sessions: [InsightSessionRow],
                                    limit: Int) -> [InsightDigest.ModelSnapshot] {
        var perModel: [String: (provider: String, cost: Double, tokens: Int,
                                cacheTokens: Int, sessions: Set<String>,
                                titles: [String: Int],
                                projects: [String: Int])] = [:]
        for u in usages {
            var entry = perModel[u.model] ?? (u.provider, 0, 0, 0, [], [:], [:])
            entry.cost += u.costUSD
            entry.tokens += u.totalTokens
            entry.cacheTokens += u.cacheReadTokens
            entry.sessions.insert(u.sessionID)
            if let p = u.projectName { entry.projects[hashedProjectID(p), default: 0] += 1 }
            perModel[u.model] = entry
        }
        // Sessions don't carry model, so we count titles per provider/model
        // approximately by joining via sessionID.
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        for u in usages {
            if let s = sessionByID[u.sessionID], let title = s.inferredTaskTitle, !title.isEmpty {
                var entry = perModel[u.model] ?? (u.provider, 0, 0, 0, [], [:], [:])
                entry.titles[title, default: 0] += 1
                perModel[u.model] = entry
            }
        }
        return perModel
            .sorted {
                $0.value.cost != $1.value.cost ? $0.value.cost > $1.value.cost : $0.key < $1.key
            }
            .prefix(limit)
            .map { key, value in
                let sessionCount = max(1, value.sessions.count)
                let avgCost = value.cost / Double(sessionCount)
                let cacheRate = value.tokens > 0 ? Double(value.cacheTokens) / Double(value.tokens) : 0
                let topTitles = Array(value.titles
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(5).map(\.key))
                let topProjects = Array(value.projects
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(3).map(\.key))
                return InsightDigest.ModelSnapshot(
                    id: key,
                    providerID: value.provider,
                    costUSD: value.cost,
                    totalTokens: value.tokens,
                    sessionCount: value.sessions.count,
                    avgCostPerSession: avgCost,
                    cacheHitRate: cacheRate,
                    topInferredTaskTitles: topTitles,
                    topProjects: topProjects
                )
            }
    }

    private func makeProjectSnapshots(usages: [InsightUsageRow], limit: Int) -> [InsightDigest.ProjectSnapshot] {
        var perProject: [String: (display: String, cost: Double, tokens: Int, sessions: Set<String>)] = [:]
        for u in usages {
            guard let p = u.projectName, !p.isEmpty else { continue }
            let id = hashedProjectID(p)
            var entry = perProject[id] ?? (lastPathComponent(of: p), 0, 0, [])
            entry.cost += u.costUSD
            entry.tokens += u.totalTokens
            entry.sessions.insert(u.sessionID)
            perProject[id] = entry
        }
        return perProject
            .sorted {
                $0.value.cost != $1.value.cost ? $0.value.cost > $1.value.cost : $0.key < $1.key
            }
            .prefix(limit)
            .map { key, value in
                InsightDigest.ProjectSnapshot(
                    id: key,
                    displayName: value.display,
                    costUSD: value.cost,
                    totalTokens: value.tokens,
                    sessionCount: value.sessions.count
                )
            }
    }

    private func makeDeviceSnapshots(usages: [InsightUsageRow], limit: Int) -> [InsightDigest.DeviceSnapshot] {
        var perDevice: [String: (display: String, cost: Double, sessions: Set<String>)] = [:]
        for u in usages {
            let realID = u.deviceID ?? "local"
            let id = hashedDeviceID(realID)
            // Display name: never the raw device name. Use a stable "Mac · A1B2"-style suffix.
            let display = u.deviceName.map { _ in deviceDisplayName(forID: id) } ?? deviceDisplayName(forID: id)
            var entry = perDevice[id] ?? (display, 0, [])
            entry.cost += u.costUSD
            entry.sessions.insert(u.sessionID)
            perDevice[id] = entry
        }
        return perDevice
            .sorted {
                $0.value.cost != $1.value.cost ? $0.value.cost > $1.value.cost : $0.key < $1.key
            }
            .prefix(limit)
            .map { key, value in
                InsightDigest.DeviceSnapshot(
                    id: key,
                    displayName: value.display,
                    costUSD: value.cost,
                    sessionCount: value.sessions.count
                )
            }
    }

    private func makeDailyPoints(usages: [InsightUsageRow], limit: Int) -> [InsightDigest.DailyPoint] {
        var perDay: [Date: (cost: Double, tokens: Int, sessions: Set<String>, perProvider: [String: Double])] = [:]
        for u in usages {
            let day = calendar.startOfDay(for: u.startTime)
            var entry = perDay[day] ?? (0, 0, [], [:])
            entry.cost += u.costUSD
            entry.tokens += u.totalTokens
            entry.sessions.insert(u.sessionID)
            entry.perProvider[u.provider, default: 0] += u.costUSD
            perDay[day] = entry
        }
        return perDay
            .sorted { $0.key < $1.key }
            .suffix(limit)
            .map { day, value in
                // Cap per-provider breakdown to top 4 to control payload size.
                let topPP = value.perProvider
                    .sorted { $0.value > $1.value }
                    .prefix(4)
                    .reduce(into: [String: Double]()) { $0[$1.key] = $1.value }
                return InsightDigest.DailyPoint(
                    day: day,
                    costUSD: value.cost,
                    totalTokens: value.tokens,
                    sessionCount: value.sessions.count,
                    perProvider: topPP
                )
            }
    }

    private func makeHourlyBuckets(usages: [InsightUsageRow]) -> [Int] {
        var buckets = Array(repeating: 0, count: 24)
        for u in usages {
            let h = calendar.component(.hour, from: u.startTime)
            if h >= 0, h < 24 { buckets[h] += 1 }
        }
        return buckets
    }

    private func makeUseCaseHistogram(sessions: [InsightSessionRow],
                                      usages: [InsightUsageRow]) -> [InsightDigest.UseCaseBin] {
        // Heuristic inference: map keyTools/keyCommands → use case tags.
        let costBySession = Dictionary(grouping: usages, by: { $0.sessionID })
            .mapValues { $0.reduce(0) { $0 + $1.costUSD } }

        var counts: [String: (Int, Double)] = [:]
        for s in sessions {
            let tag = Self.inferUseCase(session: s, taxonomy: taxonomy)
            var entry = counts[tag] ?? (0, 0)
            entry.0 += 1
            entry.1 += costBySession[s.sessionID] ?? 0
            counts[tag] = entry
        }
        return counts
            .sorted { $0.value.0 != $1.value.0 ? $0.value.0 > $1.value.0 : $0.key < $1.key }
            .map { key, value in
                InsightDigest.UseCaseBin(id: key, count: value.0, costUSD: value.1)
            }
    }

    /// Map a session to a use-case tag using a small set of rules.
    /// New rules go here; the taxonomy is the only allowed output.
    public static func inferUseCase(session: InsightSessionRow,
                                    taxonomy: InsightTaxonomy = .default) -> String {
        let tools = Set(session.keyTools.map { $0.lowercased() })
        let commands = Set(session.keyCommands.map { $0.lowercased() })
        let title = session.inferredTaskTitle?.lowercased() ?? ""

        func has(_ needles: [String], in set: Set<String>) -> Bool {
            needles.contains { n in set.contains(where: { $0.contains(n) }) }
        }

        if has(["pytest", "go test", "xctest", "jest", "rspec"], in: commands) { return tag("test-write", taxonomy) }
        if has(["git diff", "git log", "git blame"], in: commands) && title.contains("review") {
            return tag("code-review", taxonomy)
        }
        if title.contains("bug") || title.contains("fix") { return tag("bug-fix", taxonomy) }
        if title.contains("refactor") || title.contains("clean up") { return tag("refactor", taxonomy) }
        if title.contains("doc") || has(["readme.md", ".md"], in: tools) { return tag("doc-write", taxonomy) }
        if has(["explain", "why", "how does"], in: tools) || title.contains("explain") {
            return tag("code-explain", taxonomy)
        }
        if has(["docker", "kubectl", "terraform", "ansible"], in: tools) { return tag("infra-change", taxonomy) }
        if has(["sql", "bigquery", "snowflake", "pandas"], in: tools) { return tag("data-analysis", taxonomy) }
        if has(["bash", "shell", "zsh"], in: commands) { return tag("shell-script", taxonomy) }
        if has(["security", "auth", "cve", "vulnerab"], in: tools) { return tag("security-investigation", taxonomy) }
        if title.contains("perf") || title.contains("speed") { return tag("perf-investigation", taxonomy) }
        if title.contains("migrat") { return tag("migration", taxonomy) }
        return tag("feature-add", taxonomy)
    }

    private static func tag(_ desired: String, _ taxonomy: InsightTaxonomy) -> String {
        taxonomy.useCases.contains(desired) ? desired : (taxonomy.useCases.first ?? "feature-add")
    }

    private func makeAgentFocusSignals(sessions: [InsightSessionRow]) -> [InsightDigest.AgentFocusSignal] {
        var counts: [String: [String: Int]] = [:]      // agent → focus → count
        for s in sessions {
            let focus = Self.inferFocus(session: s, taxonomy: taxonomy)
            counts[s.provider, default: [:]][focus, default: 0] += 1
        }
        var out: [InsightDigest.AgentFocusSignal] = []
        for agent in counts.keys.sorted() {
            let focusCounts = counts[agent, default: [:]]
            let total = max(1, focusCounts.values.reduce(0, +))
            for focus in focusCounts.keys.sorted() {
                let count = focusCounts[focus] ?? 0
                out.append(.init(agentID: agent, focus: focus, weight: Double(count) / Double(total)))
            }
        }
        return out
    }

    private func makeModelFocusSignals(sessions: [InsightSessionRow],
                                       usages: [InsightUsageRow]) -> [InsightDigest.ModelFocusSignal] {
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        var counts: [String: [String: Int]] = [:]      // model → focus → count
        for u in usages {
            guard let s = sessionByID[u.sessionID] else { continue }
            let focus = Self.inferFocus(session: s, taxonomy: taxonomy)
            counts[u.model, default: [:]][focus, default: 0] += 1
        }
        var out: [InsightDigest.ModelFocusSignal] = []
        for model in counts.keys.sorted() {
            let focusCounts = counts[model, default: [:]]
            let total = max(1, focusCounts.values.reduce(0, +))
            for focus in focusCounts.keys.sorted() {
                let count = focusCounts[focus] ?? 0
                out.append(.init(modelID: model, focus: focus, weight: Double(count) / Double(total)))
            }
        }
        return out
    }

    /// Map a session to a high-level focus tag from the taxonomy.
    public static func inferFocus(session: InsightSessionRow,
                                  taxonomy: InsightTaxonomy = .default) -> String {
        let tools = Set(session.keyTools.map { $0.lowercased() })
        let commands = Set(session.keyCommands.map { $0.lowercased() })
        let title = session.inferredTaskTitle?.lowercased() ?? ""

        if commands.contains(where: { $0.contains("test") }) { return present("test", taxonomy) }
        if commands.contains(where: { $0.contains("git") }) && title.contains("review") { return present("review", taxonomy) }
        if tools.contains(where: { $0.hasSuffix(".md") || $0.contains("readme") }) { return present("doc", taxonomy) }
        if title.contains("refactor") { return present("refactor", taxonomy) }
        if title.contains("bug") || title.contains("fix") { return present("debug", taxonomy) }
        if tools.contains(where: { ["grep", "read", "search"].contains($0) }) { return present("research", taxonomy) }
        if tools.contains(where: { ["docker", "kubectl", "terraform"].contains($0) }) { return present("ops", taxonomy) }
        if tools.contains(where: { ["sql", "pandas", "bigquery"].contains($0) }) { return present("data", taxonomy) }
        if title.contains("design") || title.contains("layout") { return present("design", taxonomy) }
        if title.contains("explore") || title.contains("spike") { return present("explore", taxonomy) }
        return present("code", taxonomy)
    }

    private static func present(_ desired: String, _ taxonomy: InsightTaxonomy) -> String {
        taxonomy.focuses.contains(desired) ? desired : (taxonomy.focuses.first ?? "code")
    }

    private func makeActionDigests(actions: [InsightOperatingAction], limit: Int) -> [InsightDigest.ActionDigest] {
        actions
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map {
                let pid = $0.projectName.map(hashedProjectID(_:))
                let snippet = String($0.summary.prefix(160))
                return InsightDigest.ActionDigest(
                    id: $0.id,
                    kind: $0.actionKind,
                    projectID: pid,
                    occurredAt: $0.occurredAt,
                    summary: snippet
                )
            }
    }

    private func makeSummaryRunDigests(runs: [InsightSummaryRun], limit: Int) -> [InsightDigest.SummaryRunDigest] {
        runs
            .sorted { $0.ranAt > $1.ranAt }
            .prefix(limit)
            .map {
                InsightDigest.SummaryRunDigest(
                    id: $0.id,
                    providerID: $0.providerKey,
                    modelID: $0.modelID,
                    costUSD: $0.costUSD,
                    ranAt: $0.ranAt
                )
            }
    }

    private func makeAnomalies(daily: [InsightDigest.DailyPoint], limit: Int) -> [InsightDigest.PrecomputedAnomaly] {
        guard daily.count >= 5 else { return [] }
        let costs = daily.map(\.costUSD)
        // Median-and-MAD for robust z-scores.
        let median = Self.median(of: costs)
        let absDevs = costs.map { abs($0 - median) }
        let mad = max(0.0001, Self.median(of: absDevs))
        var anomalies: [InsightDigest.PrecomputedAnomaly] = []
        for (idx, point) in daily.enumerated() {
            let z = 0.6745 * (point.costUSD - median) / mad
            if abs(z) >= 2.5 {
                anomalies.append(.init(
                    id: "anomaly_\(idx)",
                    occurredAt: point.day,
                    label: z > 0 ? "Spike" : "Trough",
                    score: abs(z),
                    detail: nil
                ))
            }
        }
        return Array(anomalies.sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // MARK: - Privacy helpers

    public func hashedProjectID(_ raw: String) -> String {
        "project_" + Self.shortHash(raw, salt: "project")
    }

    public func hashedDeviceID(_ raw: String) -> String {
        "device_" + Self.shortHash(raw, salt: "device")
    }

    private func deviceDisplayName(forID hashedID: String) -> String {
        // Show last 4 of the hash suffix so the user can recognize their devices.
        let suffix = String(hashedID.suffix(4)).uppercased()
        return "Device · \(suffix)"
    }

    private func lastPathComponent(of path: String) -> String {
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? path : component
    }

    private static func shortHash(_ raw: String, salt: String) -> String {
        let bytes = SHA256.hash(data: Data("\(salt):\(raw)".utf8))
        return bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Size trimming

    /// Iteratively drop long-tail entries until the encoded digest fits.
    public func trim(_ digest: InsightDigest, toMaxBytes max: Int) throws -> InsightDigest {
        var d = digest
        var encoded = try encode(d)
        var iterations = 0
        while encoded.count > max, iterations < 32 {
            iterations += 1
            if d.useCaseHistogram.count > 4 { d.useCaseHistogram.removeLast() ; encoded = try encode(d) ; continue }
            if d.summaryRunsLog.count > 5 { d.summaryRunsLog.removeLast() ; encoded = try encode(d) ; continue }
            if d.operatingActions.count > 10 { d.operatingActions.removeLast() ; encoded = try encode(d) ; continue }
            if d.daily.count > 14 { d.daily.removeFirst() ; encoded = try encode(d) ; continue }
            if d.models.count > 4 { d.models.removeLast() ; encoded = try encode(d) ; continue }
            if d.projects.count > 3 { d.projects.removeLast() ; encoded = try encode(d) ; continue }
            if d.devices.count > 2 { d.devices.removeLast() ; encoded = try encode(d) ; continue }
            if d.providers.count > 4 { d.providers.removeLast() ; encoded = try encode(d) ; continue }
            if d.agentFocusSignals.count > 8 { d.agentFocusSignals.removeLast() ; encoded = try encode(d) ; continue }
            if d.modelFocusSignals.count > 8 { d.modelFocusSignals.removeLast() ; encoded = try encode(d) ; continue }
            if d.anomalies.count > 4 { d.anomalies.removeLast() ; encoded = try encode(d) ; continue }
            break
        }
        d.contentHash = Self.computeContentHash(digest: d)
        return d
    }

    private func encode(_ digest: InsightDigest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(digest)
    }
}
