import Foundation


enum ProjectionJobLatencyAnalytics {
    static func projectionJobLatencySummary(dataStore: DataStore, sampleLimit: Int) throws -> ProjectionJobLatencySummary {
        let completedJobs = try dataStore.fetchProjectionJobs(statuses: [.completed], limit: max(1, sampleLimit))
        guard completedJobs.isEmpty == false else {
            return ProjectionJobLatencySummary(
                sampledCompletedJobs: 0,
                queueWaitMs: nil,
                processingMs: nil,
                endToEndMs: nil
            )
        }

        let queueWaitSamples = completedJobs.compactMap { job -> Double? in
            guard let startedAt = job.startedAt else { return nil }
            return max(0, startedAt.timeIntervalSince(job.availableAt) * 1_000)
        }
        let processingSamples = completedJobs.compactMap { job -> Double? in
            guard let startedAt = job.startedAt, let completedAt = job.completedAt else { return nil }
            return max(0, completedAt.timeIntervalSince(startedAt) * 1_000)
        }
        let endToEndSamples = completedJobs.compactMap { job -> Double? in
            guard let completedAt = job.completedAt else { return nil }
            return max(0, completedAt.timeIntervalSince(job.scheduledAt) * 1_000)
        }

        return ProjectionJobLatencySummary(
            sampledCompletedJobs: completedJobs.count,
            queueWaitMs: latencyDistribution(from: queueWaitSamples),
            processingMs: latencyDistribution(from: processingSamples),
            endToEndMs: latencyDistribution(from: endToEndSamples)
        )
    }

    static func latencyDistribution(from samples: [Double]) -> ProjectionLatencyDistribution? {
        guard samples.isEmpty == false else { return nil }
        let sorted = samples.sorted()
        return ProjectionLatencyDistribution(
            count: sorted.count,
            p50Ms: percentile(50, inSortedValues: sorted),
            p95Ms: percentile(95, inSortedValues: sorted),
            maxMs: sorted.last ?? 0
        )
    }

    static func percentile(_ percentile: Double, inSortedValues sortedValues: [Double]) -> Double {
        guard sortedValues.isEmpty == false else { return 0 }
        let boundedPercentile = max(0, min(100, percentile))
        let index = Int(round((boundedPercentile / 100) * Double(sortedValues.count - 1)))
        return sortedValues[max(0, min(sortedValues.count - 1, index))]
    }
}
