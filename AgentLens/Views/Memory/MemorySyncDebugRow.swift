import SwiftUI
import OpenBurnBarCore

/// E19 / P24: Sync observability debug row across both watermarks and sync counters.
///
/// Invariants:
/// - Persists/displays last-pull timestamp, both watermark ages (engine + transport),
///   and counters (applied, rejected, parked, skipped).
/// - Alert threshold is derived from the maximum effective cadence (`BurnBarMemoryDeviceSyncMarker.maxAge`),
///   NOT the foreground interval or any arbitrary 2*600 constant.
/// - The permanent non-zero skipped floor is explicitly labelled as expected (pre-PR-1 chat memories).
public struct MemorySyncDebugRowModel: Equatable, Sendable {
    public var lastPullTimestamp: String?
    public var appliedCount: Int
    public var rejectedCount: Int
    public var parkedCount: Int
    public var skippedCount: Int
    public var engineWatermarkAgeSeconds: TimeInterval?
    public var transportWatermarkAgeSeconds: TimeInterval?
    public var alertThresholdSeconds: TimeInterval

    public var isAlertTripped: Bool {
        (engineWatermarkAgeSeconds.map { $0 > alertThresholdSeconds } ?? false) ||
        (transportWatermarkAgeSeconds.map { $0 > alertThresholdSeconds } ?? false)
    }

    public static let permanentSkippedFloorNote =
        "Pre-PR-1 chat memories in users/{uid}/memory_facts carry no engine projectID and are skipped on every pull; a permanent non-zero skipped is expected, not a fault."

    public init(
        lastPullTimestamp: String? = nil,
        appliedCount: Int = 0,
        rejectedCount: Int = 0,
        parkedCount: Int = 0,
        skippedCount: Int = 0,
        engineWatermarkAgeSeconds: TimeInterval? = nil,
        transportWatermarkAgeSeconds: TimeInterval? = nil,
        alertThresholdSeconds: TimeInterval = BurnBarMemoryDeviceSyncMarker.maxAge
    ) {
        self.lastPullTimestamp = lastPullTimestamp
        self.appliedCount = appliedCount
        self.rejectedCount = rejectedCount
        self.parkedCount = parkedCount
        self.skippedCount = skippedCount
        self.engineWatermarkAgeSeconds = engineWatermarkAgeSeconds
        self.transportWatermarkAgeSeconds = transportWatermarkAgeSeconds
        self.alertThresholdSeconds = alertThresholdSeconds
    }
}

public struct MemorySyncDebugRow: View {
    public let model: MemorySyncDebugRowModel

    public init(model: MemorySyncDebugRowModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memory Sync Observability")
                    .font(.headline)
                Spacer()
                if model.isAlertTripped {
                    Label("Stale Watermark Alert", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Label("Healthy", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Text("Last Pull: \(model.lastPullTimestamp ?? "None")")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Engine Watermark Age: \(formatAge(model.engineWatermarkAgeSeconds))")
                    Text("Transport Watermark Age: \(formatAge(model.transportWatermarkAgeSeconds))")
                }
                .font(.caption)

                Spacer()

                HStack(spacing: 12) {
                    Text("Applied: \(model.appliedCount)")
                    Text("Rejected: \(model.rejectedCount)")
                    Text("Parked: \(model.parkedCount)")
                    Text("Skipped: \(model.skippedCount)")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Text(MemorySyncDebugRowModel.permanentSkippedFloorNote)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
    }

    private func formatAge(_ age: TimeInterval?) -> String {
        guard let age else { return "Unknown" }
        if age < 60 {
            return String(format: "%.0fs", age)
        } else {
            return String(format: "%.1fm", age / 60.0)
        }
    }
}
