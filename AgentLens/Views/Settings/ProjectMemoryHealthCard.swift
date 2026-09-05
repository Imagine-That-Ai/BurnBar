import Foundation
import Observation
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

// MARK: - Host model

/// Owns one health card's three reads: WHICH project, the daemon's counters for
/// it, and this Mac's own snapshot.
///
/// **Which project, and why that is the hard part.** `daemon.memory.analytics`
/// takes a `projectPath` and resolves it through
/// `BurnBarProjectCodeMemoryStore.resolveProjectIdentity` — the WRITING resolver:
/// it `INSERT OR IGNORE`s into `pcm_projects`, rewrites `updated_at`, and upserts
/// `pcm_project_aliases`. A nil path is resolved against
/// `FileManager.default.currentDirectoryPath`, which the daemon's LaunchAgent
/// pins to its own support directory. So asking with `nil` would (a) register a
/// phantom project named after the daemon's install directory every time Settings
/// opened and (b) render that directory's `total: 0` as a measurement of the
/// member's project. Both are exactly the fabrication this surface exists to
/// prevent.
///
/// So the model never invents a subject. It lists the projects the daemon has
/// ALREADY recorded (a read-only `SELECT` on the shared database), the member
/// picks one — defaulting to the most recently written — and the RPC carries that
/// project's own recorded root, which the daemon's resolver matches to the
/// existing fingerprint/alias and therefore does not register. With no recorded
/// project there is no subject at all, and the card says so instead of asking.
@MainActor @Observable
final class ProjectMemoryHealthModel {

    typealias LoadProjects = () async throws -> [MemoryHealthProject]
    typealias LoadSnapshot = () async throws -> MemoryHealthLocalSnapshot
    /// Takes a NON-OPTIONAL recorded root: the type makes "ask about nothing in
    /// particular" unrepresentable.
    typealias FetchAnalytics = (_ recordedRoot: String) async -> BurnBarProjectMemoryAnalyticsResponse?

    /// What the card says when the daemon has never indexed a project here.
    static let noProjectsNote =
        "No project memories yet — the daemon has not indexed a project on this Mac, so there is nothing to measure."

    private(set) var projects: [MemoryHealthProject] = []
    private(set) var selectedProjectID: String?
    private(set) var card: ProjectMemoryHealthCardModel?
    private(set) var loadFailure: String?
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    /// True only once a load has finished and found nothing. Never true while
    /// loading, and never true after a failure — "we could not look" is not
    /// "there is nothing".
    var hasNoKnownProjects: Bool {
        hasLoaded && loadFailure == nil && projects.isEmpty
    }

    var noProjectsNote: String { Self.noProjectsNote }

    var selectedProject: MemoryHealthProject? {
        projects.first { $0.id == selectedProjectID }
    }

    private let loadProjects: LoadProjects
    private let loadSnapshot: LoadSnapshot
    private let fetchAnalytics: FetchAnalytics

    init(
        loadProjects: @escaping LoadProjects,
        loadSnapshot: @escaping LoadSnapshot,
        fetchAnalytics: @escaping FetchAnalytics
    ) {
        self.loadProjects = loadProjects
        self.loadSnapshot = loadSnapshot
        self.fetchAnalytics = fetchAnalytics
    }

    func load() async {
        guard isLoading == false else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            projects = try await loadProjects()
        } catch {
            projects = []
            card = nil
            loadFailure = error.localizedDescription
            return
        }

        // No recorded project: no subject, so no request. The card renders the
        // note instead of a zero it would have had to invent a project to get.
        guard let first = projects.first else {
            selectedProjectID = nil
            card = nil
            loadFailure = nil
            return
        }

        await refresh(project: first)
    }

    /// Switches the card to another recorded project, asking about THAT project.
    func select(_ projectID: String) async {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        await refresh(project: project)
    }

    private func refresh(project: MemoryHealthProject) async {
        selectedProjectID = project.id
        // The ONLY call site. `project.recordedRoot` came out of `pcm_projects`,
        // so the daemon's resolver finds it and inserts nothing.
        let analytics = await fetchAnalytics(project.recordedRoot)
        do {
            let snapshot = try await loadSnapshot()
            card = ProjectMemoryHealthCardModel(
                analytics: analytics,
                snapshot: snapshot,
                projectName: project.name,
                projectRoot: project.recordedRoot
            )
            loadFailure = nil
        } catch {
            card = nil
            loadFailure = error.localizedDescription
        }
    }
}

// MARK: - Host

/// Mounts `ProjectMemoryHealthModel` and its picker.
///
/// The model is held in `@State` so a Settings re-render cannot replace a loaded
/// card with a fresh empty one — and, more importantly, cannot re-issue the
/// daemon request as a side effect of an unrelated redraw.
@MainActor
struct ProjectMemoryHealthCardHost: View {
    let store: ControlPlaneStore
    let daemonManager: OpenBurnBarDaemonManager?
    let accountUid: String?

    @State private var model: ProjectMemoryHealthModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                loadingRow
            }
        }
        .task {
            let model = model ?? makeModel()
            self.model = model
            guard model.hasLoaded == false else { return }
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ model: ProjectMemoryHealthModel) -> some View {
        if let card = model.card {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                projectPicker(model)
                ProjectMemoryHealthCard(model: card)
            }
        } else if let failure = model.loadFailure {
            unavailable(failure)
        } else if model.hasNoKnownProjects {
            noProjects(model.noProjectsNote)
        } else {
            loadingRow
        }
    }

    /// Only shown when there is a choice to make. One recorded project needs no
    /// picker; the card's own header already names it.
    @ViewBuilder
    private func projectPicker(_ model: ProjectMemoryHealthModel) -> some View {
        if model.projects.count > 1 {
            Picker(
                "Project",
                selection: Binding(
                    get: { model.selectedProjectID ?? "" },
                    set: { id in Task { await model.select(id) } }
                )
            ) {
                ForEach(model.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(DesignSystem.Typography.tiny)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text("Checking memory health…")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func noProjects(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "tray")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(detail)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
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

    private func makeModel() -> ProjectMemoryHealthModel {
        let store = store
        let daemonManager = daemonManager
        let accountUid = accountUid
        return ProjectMemoryHealthModel(
            loadProjects: { try await store.memoryHealthProjects() },
            loadSnapshot: { try await store.memoryHealthLocalSnapshot(accountUid: accountUid) },
            fetchAnalytics: { recordedRoot in
                guard let daemonManager else { return nil }
                let socketURL = daemonManager.paths.socketURL
                do {
                    // Nil on any failure — an unreachable or refusing daemon
                    // leaves the counters unmeasured rather than zeroed.
                    return try await daemonManager.daemonRPC {
                        try OpenBurnBarDaemonSocketClient.memoryAnalytics(
                            projectPath: recordedRoot,
                            at: socketURL
                        )
                    }
                } catch {
                    AppLogger.dataStore.silentFailure("daemon.memory.analytics unavailable", error: error)
                    return nil
                }
            }
        )
    }
}
