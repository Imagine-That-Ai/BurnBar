import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Models
//
// B11: a per-project memory health card built ONLY from things that already
// exist — the counters `daemon.memory.analytics` already serves, and the checks
// this Mac can run on its own database. No new RPC, no new table, no new
// counter, no new engine field.
//
// The card's discipline is what it REFUSES to say. The engine's doctor runs
// inside the Python engine against a store no Swift process reads, so its
// findings are absent here and the card says so out loud rather than letting an
// empty list read as a clean bill. An unreachable daemon renders `—`, never `0`:
// "we could not ask" and "you have no memories" are different statements.

/// One health finding, in the engine's `{severity, code, detail, fix}` shape so
/// an engine-sourced finding could join these without reshaping.
struct ProjectMemoryHealthFinding: Codable, Equatable, Identifiable, Sendable {
    var id: String { code }
    let code: String
    let severity: String
    let detail: String
    let fix: String?

    init(
        code: String,
        severity: String,
        detail: String,
        fix: String? = nil
    ) {
        self.code = code
        self.severity = severity
        self.detail = detail
        self.fix = fix
    }
}

struct ProjectMemoryHealthCardModel: Equatable, Sendable {
    let projectID: String
    let projectName: String?
    let projectRoot: String?
    let status: String
    /// Nil when the daemon could not be asked. Rendered as `placeholder`, never
    /// as `0`.
    let totalMemories: Int?
    let byKind: [String: Int]
    let byScope: [String: Int]
    let lastAuditHash: String?
    let errorCount: Int
    let warningCount: Int
    let infoCount: Int
    let severityCounts: [String: Int]
    let findings: [ProjectMemoryHealthFinding]
    let auditChainOK: Bool
    let lastPullAge: String
    let markerAge: String

    /// What a stat shows when the number behind it does not exist. A daemon that
    /// could not be reached has no counters — saying `0` would assert an empty
    /// store that was never observed.
    static let placeholder = "—"

    /// `status` when the daemon could not be asked at all.
    static let statusUnavailable = "unavailable"

    /// The labelled statement that keeps an empty findings list honest.
    var engineDoctorNote: String { MemoryHealthLocalFindings.engineDoctorNotMeasuredNote }

    /// The stats the card renders, in order. Exposed as data so the rendered
    /// values — including the placeholders — are assertable without a snapshot.
    var statRows: [StatRow] {
        var rows: [StatRow] = [
            StatRow(title: "Memories", value: totalMemories.map(String.init) ?? Self.placeholder),
            StatRow(
                title: "Audit chain",
                value: auditChainOK ? "Intact" : "Broken",
                emphasis: auditChainOK ? .good : .bad
            ),
            StatRow(title: "Last pull", value: lastPullAge),
            StatRow(title: "Marker age", value: markerAge)
        ]
        if byKind.isEmpty == false {
            rows.append(StatRow(title: "Kinds", value: "\(byKind.count)"))
        }
        return rows
    }

    struct StatRow: Equatable, Identifiable, Sendable {
        enum Emphasis: Equatable, Sendable {
            case neutral
            case good
            case bad
        }

        let title: String
        let value: String
        let emphasis: Emphasis

        var id: String { title }

        init(title: String, value: String, emphasis: Emphasis = .neutral) {
            self.title = title
            self.value = value
            self.emphasis = emphasis
        }
    }

    /// The typed init. `analytics` is the daemon's own response decoded
    /// verbatim; `findings` are the app-producible ones from
    /// `MemoryHealthLocalFindings`, and nothing else may be passed here — the
    /// card asserts the codes it renders are ones this Mac actually measured.
    init(
        analytics: BurnBarProjectMemoryAnalyticsResponse?,
        findings: [ProjectMemoryHealthFinding] = [],
        projectName: String? = nil,
        projectRoot: String? = nil,
        lastPullAge: String = Self.placeholder,
        markerAge: String = Self.placeholder
    ) {
        self.projectID = analytics?.projectID ?? ""
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.totalMemories = analytics?.total
        self.byKind = analytics?.byKind ?? [:]
        self.byScope = analytics?.byScope ?? [:]
        self.lastAuditHash = analytics?.lastAuditHash
        self.findings = findings

        var errors = 0
        var warnings = 0
        var infos = 0
        var counts: [String: Int] = [:]
        for finding in findings {
            counts[finding.severity, default: 0] += 1
            switch finding.severity {
            case MemoryHealthLocalFindings.severityError:
                errors += 1
            case MemoryHealthLocalFindings.severityWarn, "warning":
                warnings += 1
            case "info":
                infos += 1
            default:
                break
            }
        }
        self.errorCount = errors
        self.warningCount = warnings
        self.infoCount = infos
        self.severityCounts = counts
        // An unreported chain is not a broken one; only a finding that says the
        // chain broke may claim it did.
        self.auditChainOK = findings.contains { $0.code == MemoryHealthLocalFindings.auditChainBroken } == false
        self.status = analytics == nil
            ? Self.statusUnavailable
            : (errors > 0 ? "degraded" : "ok")
        self.lastPullAge = lastPullAge
        self.markerAge = markerAge
    }

    /// Convenience over the two halves the app actually holds: the daemon's
    /// counters and this Mac's own snapshot. Ages come from the sync watermarks,
    /// not from a guess.
    init(
        analytics: BurnBarProjectMemoryAnalyticsResponse?,
        snapshot: MemoryHealthLocalSnapshot,
        secretScannerAvailable: Bool = MemorySecretPIIGate.isAvailable,
        projectName: String? = nil,
        projectRoot: String? = nil,
        now: Date = Date()
    ) {
        self.init(
            analytics: analytics,
            findings: MemoryHealthLocalFindings.findings(
                snapshot: snapshot,
                secretScannerAvailable: secretScannerAvailable,
                now: now
            ),
            projectName: projectName,
            projectRoot: projectRoot,
            lastPullAge: MemoryHealthLocalFindings.age(of: snapshot.lastMemoryFactsPullAt, now: now),
            markerAge: MemoryHealthLocalFindings.age(of: snapshot.deviceSyncMarkerRefreshedAt, now: now)
        )
    }
}

// MARK: - View

struct ProjectMemoryHealthCard: View {
    let model: ProjectMemoryHealthCardModel

    init(model: ProjectMemoryHealthCardModel) {
        self.model = model
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                header

                Divider().background(DesignSystem.Colors.border.opacity(0.4))

                HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                    ForEach(model.statRows) { row in
                        statColumn(row)
                    }
                    Spacer(minLength: 0)
                }

                severityRow

                if !model.findings.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        ForEach(model.findings) { finding in
                            findingRow(finding)
                        }
                    }
                }

                engineDoctorNote
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.ember)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.projectName ?? (model.projectID.isEmpty ? "Project memory" : model.projectID))
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                if let root = model.projectRoot, !root.isEmpty {
                    Text(root)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            statusPill
        }
    }

    private var statusPill: some View {
        let isUnavailable = model.status == ProjectMemoryHealthCardModel.statusUnavailable
        let isHealthy = model.errorCount == 0 && model.status == "ok"
        let tint: Color = isUnavailable
            ? DesignSystem.Colors.textMuted
            : (isHealthy ? DesignSystem.Colors.success : (model.errorCount > 0 ? DesignSystem.Colors.error : DesignSystem.Colors.amber))
        let label = isUnavailable
            ? "Daemon unreachable"
            : (isHealthy ? "Healthy" : (model.errorCount > 0 ? "Degraded" : "Warning"))

        return HStack(spacing: DesignSystem.Spacing.xxs) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.medium)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var severityRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if model.errorCount > 0 {
                severityTag(count: model.errorCount, label: "errors", tint: DesignSystem.Colors.error)
            }
            if model.warningCount > 0 {
                severityTag(count: model.warningCount, label: "warnings", tint: DesignSystem.Colors.amber)
            }
            if model.errorCount == 0 && model.warningCount == 0 {
                Text("Nothing this Mac can check is failing")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    /// The labelled block. Without it, an empty findings list would read as
    /// "the doctor found nothing" instead of "the doctor never ran here".
    private var engineDoctorNote: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(.top, 1)
            Text(model.engineDoctorNote)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func statColumn(_ row: ProjectMemoryHealthCardModel.StatRow) -> some View {
        let tint: Color = switch row.emphasis {
        case .neutral: DesignSystem.Colors.textPrimary
        case .good: DesignSystem.Colors.success
        case .bad: DesignSystem.Colors.error
        }

        return VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(row.value)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
        }
    }

    private func severityTag(count: Int, label: String, tint: Color) -> some View {
        Text("\(count) \(label)")
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(tint)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }

    private func findingRow(_ finding: ProjectMemoryHealthFinding) -> some View {
        let isError = finding.severity == MemoryHealthLocalFindings.severityError
        let tint = isError ? DesignSystem.Colors.error : DesignSystem.Colors.amber

        return HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(finding.code)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
                Text(finding.detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = finding.fix {
                    Text("Fix: \(fix)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(tint.opacity(0.06))
        )
    }
}

// MARK: - Host

/// Owns one health card's two reads: the daemon's counters and this Mac's own
/// snapshot.
///
/// The two halves fail independently on purpose. A daemon that cannot be reached
/// leaves the counters absent — the card renders `—`, never `0` — while the
/// local checks still run. A local read that fails says so instead of drawing a
/// card whose "nothing is failing" line was never earned.
@MainActor
struct ProjectMemoryHealthCardHost: View {
    let store: ControlPlaneStore
    let daemonManager: OpenBurnBarDaemonManager?
    let accountUid: String?
    let projectRoot: String?

    @State private var model: ProjectMemoryHealthCardModel?
    @State private var localCheckFailure: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let model {
                ProjectMemoryHealthCard(model: model)
            } else if let localCheckFailure {
                unavailable(localCheckFailure)
            } else if isLoading {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Checking memory health…")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
        .task { await load() }
    }

    private func unavailable(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.amber)
            Text("Memory health checks could not run — \(detail)")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let analytics = await fetchAnalytics()
        do {
            let snapshot = try await store.memoryHealthLocalSnapshot(accountUid: accountUid)
            model = ProjectMemoryHealthCardModel(
                analytics: analytics,
                snapshot: snapshot,
                projectRoot: projectRoot
            )
            localCheckFailure = nil
        } catch {
            model = nil
            localCheckFailure = error.localizedDescription
        }
    }

    /// Nil on any failure — an unreachable or refusing daemon leaves the
    /// counters unmeasured rather than zeroed.
    private func fetchAnalytics() async -> BurnBarProjectMemoryAnalyticsResponse? {
        guard let daemonManager else { return nil }
        let socketURL = daemonManager.paths.socketURL
        let projectPath = projectRoot
        do {
            return try await daemonManager.daemonRPC {
                try OpenBurnBarDaemonSocketClient.memoryAnalytics(projectPath: projectPath, at: socketURL)
            }
        } catch {
            AppLogger.dataStore.silentFailure("daemon.memory.analytics unavailable", error: error)
            return nil
        }
    }
}
