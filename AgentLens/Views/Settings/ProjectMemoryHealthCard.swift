import Foundation
import SwiftUI

// MARK: - Models
//
// B11: a per-project memory health card built ONLY from output that already
// exists — `burnbar_memory_doctor`'s JSON and `burnbar_memory_analytics`'
// counters. No new app table, no new counter, no new engine field.
//
// Not yet mounted: the app has no reader for either JSON payload today, so the
// card is the presentation half waiting on one. Feeding it is one initialiser
// call with the decoded dictionaries.

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
    let totalMemories: Int
    let errorCount: Int
    let warningCount: Int
    let infoCount: Int
    let severityCounts: [String: Int]
    let findings: [ProjectMemoryHealthFinding]
    let auditChainOK: Bool
    let embeddingCoverage: Double?
    let vaultEntries: Int?
    let lastPullAge: String
    let markerAge: String

    /// What a stat shows when the number behind it does not exist yet. Sync
    /// observability (last pull / marker age) lands with E19; until then the card
    /// says so instead of inventing a zero.
    static let placeholder = "—"

    /// The stats the card renders, in order. Exposed as data so the rendered
    /// values — including the placeholders — are assertable without a snapshot.
    var statRows: [StatRow] {
        var rows: [StatRow] = [
            StatRow(title: "Memories", value: "\(totalMemories)"),
            StatRow(
                title: "Audit chain",
                value: auditChainOK ? "Intact" : "Broken",
                emphasis: auditChainOK ? .good : .bad
            ),
            StatRow(title: "Last pull", value: lastPullAge),
            StatRow(title: "Marker age", value: markerAge)
        ]
        if let embeddingCoverage {
            rows.append(StatRow(title: "Embedded", value: "\(Int((embeddingCoverage * 100).rounded()))%"))
        }
        if let vaultEntries {
            rows.append(StatRow(title: "Vault", value: "\(vaultEntries)"))
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

    init(
        projectID: String,
        projectName: String? = nil,
        projectRoot: String? = nil,
        status: String = "ok",
        totalMemories: Int = 0,
        errorCount: Int = 0,
        warningCount: Int = 0,
        infoCount: Int = 0,
        severityCounts: [String: Int] = [:],
        findings: [ProjectMemoryHealthFinding] = [],
        auditChainOK: Bool = true,
        embeddingCoverage: Double? = nil,
        vaultEntries: Int? = nil,
        lastPullAge: String = Self.placeholder,
        markerAge: String = Self.placeholder
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.status = status
        self.totalMemories = totalMemories
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.infoCount = infoCount
        self.severityCounts = severityCounts
        self.findings = findings
        self.auditChainOK = auditChainOK
        self.embeddingCoverage = embeddingCoverage
        self.vaultEntries = vaultEntries
        self.lastPullAge = lastPullAge
        self.markerAge = markerAge
    }

    /// Aggregates `burnbar_memory_doctor` JSON (`memory_engine/_admin.py`, `doctor`)
    /// and `burnbar_memory_analytics` JSON (`_admin.py`, `stats`) into the card.
    ///
    /// Every key read here is one the engine already emits: `status`,
    /// `projectID` / `projectName` / `projectRoot`, `engine.memories`,
    /// `auditChain.ok`, and `findings[].{severity,code,detail,fix}` from doctor;
    /// `total`, `embeddingCoverage`, `vaultEntries` from analytics. Severities
    /// are the engine's own `error` / `warn` (`warning` is accepted so an engine
    /// that spells it out does not silently drop out of the counts).
    init(
        doctorJSON: [String: Any],
        analyticsJSON: [String: Any]? = nil,
        lastPullAge: String? = nil,
        markerAge: String? = nil
    ) {
        // The project identity travels on doctor's payload only; `stats` returns
        // counters, not a project payload.
        let projectID = (doctorJSON["projectID"] as? String) ?? ""
        let projectName = doctorJSON["projectName"] as? String
        let projectRoot = doctorJSON["projectRoot"] as? String
        let status = (doctorJSON["status"] as? String) ?? "ok"

        // Doctor counts every row in the store; analytics counts the live rows of
        // one project. Doctor wins when present so the card and doctor agree.
        let engineTotal = (doctorJSON["engine"] as? [String: Any])?["memories"] as? Int
        let total = engineTotal ?? (analyticsJSON?["total"] as? Int) ?? 0

        let auditOK = ((doctorJSON["auditChain"] as? [String: Any])?["ok"] as? Bool) ?? true

        // Findings
        var parsedFindings: [ProjectMemoryHealthFinding] = []
        var errors = 0
        var warnings = 0
        var infos = 0
        var counts: [String: Int] = [:]

        if let rawFindings = doctorJSON["findings"] as? [[String: Any]] {
            for dict in rawFindings {
                let code = (dict["code"] as? String) ?? "UNKNOWN"
                let severity = (dict["severity"] as? String) ?? "info"
                let detail = (dict["detail"] as? String) ?? ""
                let fix = dict["fix"] as? String

                parsedFindings.append(ProjectMemoryHealthFinding(
                    code: code,
                    severity: severity,
                    detail: detail,
                    fix: fix
                ))

                counts[severity, default: 0] += 1
                switch severity {
                case "error":
                    errors += 1
                case "warn", "warning":
                    warnings += 1
                case "info":
                    infos += 1
                default:
                    break
                }
            }
        }

        // Analytics counters
        let embCov = (analyticsJSON?["embeddingCoverage"] as? Double)
            ?? (analyticsJSON?["embeddingCoverage"] as? NSNumber)?.doubleValue
        let vault = (analyticsJSON?["vaultEntries"] as? Int)
            ?? (analyticsJSON?["vaultEntries"] as? NSNumber)?.intValue

        self.projectID = projectID
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.status = status
        self.totalMemories = total
        self.errorCount = errors
        self.warningCount = warnings
        self.infoCount = infos
        self.severityCounts = counts
        self.findings = parsedFindings
        self.auditChainOK = auditOK
        self.embeddingCoverage = embCov
        self.vaultEntries = vault
        // Sync observability is not in either payload yet (E19 adds both
        // watermarks); the card says "not measured" rather than "zero".
        self.lastPullAge = lastPullAge ?? Self.placeholder
        self.markerAge = markerAge ?? Self.placeholder
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
                // Header
                HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.ember)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.projectName ?? model.projectID)
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

                Divider().background(DesignSystem.Colors.border.opacity(0.4))

                // Stats row, straight off the model so what is asserted is what
                // is drawn.
                HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                    ForEach(model.statRows) { row in
                        statColumn(row)
                    }
                }

                // Severity Breakdown / Pills
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if model.errorCount > 0 {
                        severityTag(count: model.errorCount, label: "errors", tint: DesignSystem.Colors.error)
                    }
                    if model.warningCount > 0 {
                        severityTag(count: model.warningCount, label: "warnings", tint: DesignSystem.Colors.amber)
                    }
                    if model.errorCount == 0 && model.warningCount == 0 {
                        Text("No doctor issues detected")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }

                // Findings list (if any)
                if !model.findings.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        ForEach(model.findings) { finding in
                            findingRow(finding)
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var statusPill: some View {
        let isHealthy = model.errorCount == 0 && model.status == "ok"
        let tint = isHealthy ? DesignSystem.Colors.success : (model.errorCount > 0 ? DesignSystem.Colors.error : DesignSystem.Colors.amber)
        let label = isHealthy ? "Healthy" : (model.errorCount > 0 ? "Degraded" : "Warning")

        return HStack(spacing: DesignSystem.Spacing.xxs) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.medium)
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
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Text("\(count) \(label)")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .padding(.vertical, DesignSystem.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private func findingRow(_ finding: ProjectMemoryHealthFinding) -> some View {
        let isError = finding.severity == "error"
        let tint = isError ? DesignSystem.Colors.error : DesignSystem.Colors.amber

        return HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(finding.code)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(tint)
                    Spacer()
                }
                Text(finding.detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                if let fix = finding.fix {
                    Text("Fix: \(fix)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
        .padding(DesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(tint.opacity(0.06))
        )
    }
}
