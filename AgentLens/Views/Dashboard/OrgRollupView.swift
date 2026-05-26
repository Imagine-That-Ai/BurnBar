import SwiftUI
import OpenBurnBarCore

/// Enterprise cross-seat rollup: spend by user, project, credential, or provider.
/// Gated behind `SettingsManager.enterpriseOrgViewEnabled` (default off).
///
/// Data comes from the local `token_usage` table which `CloudSyncService` already
/// syncs from every seat — the `sourceDeviceID` and `sourceDeviceName` columns
/// distinguish per-seat contributions. No separate Firestore aggregation pipeline
/// is needed for the MVP; the MCP `burnbar_org_spend` tool provides the same data
/// to Hermes and external clients.
struct OrgRollupView: View {
    @State private var groupBy: OrgGroupBy = .user
    @State private var period: BudgetPeriod = .month
    @State private var rollups: [OrgRollupRow] = []
    @State private var isLoading = false

    var dataStore: DataStoreCoordinator
    @Environment(SettingsManager.self) private var settingsManager

    var body: some View {
        Group {
            if !settingsManager.cloudSync.enterpriseOrgViewEnabled {
                disabledView
            } else {
                rollupContent
            }
        }
        .navigationTitle("Organization Rollup")
        .task { loadRollups() }
        .refreshable { loadRollups() }
    }

    // MARK: - Disabled state

    private var disabledView: some View {
        ContentUnavailableView(
            "Organization view is off",
            systemImage: "building.2",
            description: Text("Enable it in Settings → Cloud → Organization view.")
        )
    }

    // MARK: - Content

    private var rollupContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pickerBar
            Divider()
            if isLoading {
                ProgressView("Loading rollup…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rollups.isEmpty {
                ContentUnavailableView(
                    "No cross-seat data",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Spend data from other seats will appear here once CloudSync downloads it.")
                )
            } else {
                rollupList
            }
        }
    }

    private var pickerBar: some View {
        HStack(spacing: 16) {
            Picker("Group by", selection: $groupBy) {
                ForEach(OrgGroupBy.allCases) { g in
                    Text(g.label).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Picker("Period", selection: $period) {
                Text("Day").tag(BudgetPeriod.day)
                Text("Week").tag(BudgetPeriod.week)
                Text("Month").tag(BudgetPeriod.month)
                Text("All time").tag(BudgetPeriod.allTime)
            }
            .pickerStyle(.menu)

            Spacer()

            Button {
                loadRollups()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh rollup")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DesignSystem.Colors.surface)
    }

    private var rollupList: some View {
        List(rollups) { row in
            HStack(spacing: 12) {
                Image(systemName: groupBy.icon)
                    .foregroundStyle(groupBy.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text("\(row.deviceCount) \(row.deviceCount == 1 ? "device" : "devices") · \(row.sessionCount) sessions")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("$\(String(format: "%.2f", row.totalCost))")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text("\(String(format: "%.0f", row.totalTokens)) tokens")
                        .font(.caption2.monospaced())
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    // MARK: - Data loading

    private func loadRollups() {
        isLoading = true
        rollups = queryOrgRollup()
        isLoading = false
    }

    /// Queries token_usage grouped by the selected dimension. Reuses the same GROUP BY
    /// pattern as `UsageStore.makeProjectSpendSummaries` but adds `sourceDeviceID` /
    /// `sourceDeviceName` for per-seat attribution.
    private func queryOrgRollup() -> [OrgRollupRow] {
        do {
            return try dataStore.usageStore.fetchOrgRollup(groupBy: groupBy, period: period)
        } catch {
            return []
        }
    }
}

// MARK: - Types

enum OrgGroupBy: String, CaseIterable, Identifiable {
    case user
    case project
    case credential
    case provider

    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: return "User / Seat"
        case .project: return "Project"
        case .credential: return "Credential"
        case .provider: return "Provider"
        }
    }

    var icon: String {
        switch self {
        case .user: return "person.2.fill"
        case .project: return "folder.fill"
        case .credential: return "key.fill"
        case .provider: return "server.rack"
        }
    }

    var tint: Color {
        switch self {
        case .user: return .purple
        case .project: return .green
        case .credential: return .orange
        case .provider: return .blue
        }
    }
}

struct OrgRollupRow: Identifiable {
    let id = UUID()
    let label: String
    let totalCost: Double
    let totalTokens: Double
    let sessionCount: Int
    let deviceCount: Int
}

#if DEBUG
#Preview("Org Rollup — disabled") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Organization Rollup")
                .font(.title)
            Text("Enable in Settings → Cloud → Organization view to see cross-seat spend data.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
    .frame(width: 720, height: 480)
}
#endif
