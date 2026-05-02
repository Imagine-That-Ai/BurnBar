import Foundation

// MARK: - Local Metrics Aggregator

/// Lightweight operational metrics computed from the existing `retrieval_health`
/// table plus in-memory counters. No external telemetry endpoints.
actor LocalMetricsAggregator {
    private let dataStore: DataStore
    private let counter = LocalMetricsCounter()
    private var latestSnapshot: LocalMetricsSnapshot?
    private var lastCompute: Date = .distantPast

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Public API

    var currentSnapshot: LocalMetricsSnapshot? { latestSnapshot }

    func recordEvent(_ subsystem: LocalMetricsSubsystem, key: String, delta: Int = 1) async {
        await counter.increment("\(subsystem.rawValue).\(key)")
    }

    func compute(window: TimeInterval = 3600) async {
        let now = Date()
        let since = now.addingTimeInterval(-window)

        do {
            let healthRecords = try dataStore.fetchRetrievalHealth()
            let searchRecords = healthRecords.filter { $0.subsystem == .lexical || $0.subsystem == .semantic }
            let snapshot = Self.buildSnapshot(
                searchRecords: searchRecords,
                allRecords: healthRecords,
                counterSnapshot: await counter.snapshot(since: since),
                windowStart: since,
                windowEnd: now
            )
            latestSnapshot = snapshot
            lastCompute = now

            AppLogger.metrics.info("computed", metadata: [
                "searchP50": String(format: "%.1f", snapshot.searchP50Ms ?? 0),
                "recordCount": "\(healthRecords.count)"
            ])
        } catch {
            AppLogger.metrics.silentFailure("compute", error: error)
        }
    }

    func startPeriodicCompute(interval: TimeInterval = 60) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self.compute()
            }
        }
    }

    // MARK: - Snapshot Builder

    private static func buildSnapshot(
        searchRecords: [RetrievalHealthRecord],
        allRecords: [RetrievalHealthRecord],
        counterSnapshot: [String: Int],
        windowStart: Date,
        windowEnd: Date
    ) -> LocalMetricsSnapshot {
        let searchLatencies = searchRecords.compactMap { record -> Double? in
            guard let json = record.detailsJSON,
                  let data = json.data(using: .utf8),
                  let details = try? JSONDecoder().decode(LexicalRetrievalHealthDetails.self, from: data) else {
                return nil
            }
            return details.totalQueryLatencyMs
        }

        let lexicalLatencies = searchRecords.compactMap { record -> Double? in
            guard record.subsystem == .lexical,
                  let json = record.detailsJSON,
                  let data = json.data(using: .utf8),
                  let details = try? JSONDecoder().decode(LexicalRetrievalHealthDetails.self, from: data) else {
                return nil
            }
            return details.lexicalQueryLatencyMs
        }

        let semanticLatencies = searchRecords.compactMap { record -> Double? in
            guard record.subsystem == .semantic,
                  let json = record.detailsJSON,
                  let data = json.data(using: .utf8),
                  let details = try? JSONDecoder().decode(LexicalRetrievalHealthDetails.self, from: data) else {
                return nil
            }
            return details.semanticQueryLatencyMs
        }

        let rerankRecords = searchRecords.filter { record in
            guard let json = record.detailsJSON,
                  let data = json.data(using: .utf8),
                  let details = try? JSONDecoder().decode(LexicalRetrievalHealthDetails.self, from: data) else {
                return false
            }
            return details.crossEncoderLatencyMs != nil
        }
        let rerankSuccessRate = rerankRecords.isEmpty ? nil : Double(rerankRecords.filter { $0.status != .failed }.count) / Double(rerankRecords.count)

        let semanticFallbackRecords = searchRecords.filter { record in
            guard let json = record.detailsJSON,
                  let data = json.data(using: .utf8),
                  let details = try? JSONDecoder().decode(LexicalRetrievalHealthDetails.self, from: data) else {
                return false
            }
            return details.semanticFallbackUsed
        }
        let semanticFallbackRate = searchRecords.isEmpty ? nil : Double(semanticFallbackRecords.count) / Double(searchRecords.count)

        let parserEvents = counterSnapshot["parser.events"]
        let parserEventsPerMinute: Double? = parserEvents.map { Double($0) / windowEnd.timeIntervalSince(windowStart) * 60 }

        let syncRecords = allRecords.filter { $0.subsystem == .collaboration }
        let syncSuccessRate = syncRecords.isEmpty ? nil : Double(syncRecords.filter { $0.status == .healthy }.count) / Double(syncRecords.count)

        let projectionRecords = allRecords.filter { $0.subsystem == .projection }
        let projectionFailureRate = projectionRecords.isEmpty ? nil : Double(projectionRecords.filter { $0.status == .failed }.count) / Double(projectionRecords.count)

        return LocalMetricsSnapshot(
            windowStart: windowStart,
            windowEnd: windowEnd,
            searchP50Ms: percentile(searchLatencies, p: 0.5),
            searchP95Ms: percentile(searchLatencies, p: 0.95),
            searchP99Ms: percentile(searchLatencies, p: 0.99),
            lexicalP50Ms: percentile(lexicalLatencies, p: 0.5),
            semanticP50Ms: percentile(semanticLatencies, p: 0.5),
            rerankSuccessRate: rerankSuccessRate,
            semanticFallbackRate: semanticFallbackRate,
            parserEventsPerMinute: parserEventsPerMinute,
            syncSuccessRate: syncSuccessRate,
            projectionJobsPerMinute: nil,
            projectionFailureRate: projectionFailureRate
        )
    }

    // MARK: - Helpers

    private static func percentile(_ values: [Double], p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Double(sorted.count - 1) * p
        let lower = Int(index)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = index - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }
}
