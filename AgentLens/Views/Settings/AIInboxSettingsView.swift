import SwiftUI
import OpenBurnBarKernel

/// Settings for the AI Inbox.
///
/// Two things this screen must do well, because they are the whole trust story:
///
///   1. **Make the egress decision legible.** The default sends nothing off the
///      device, and the copy says exactly what each mode does rather than making
///      the user infer it from a switch label.
///   2. **Show what it actually costs.** Live tick telemetry — how often it ran,
///      how often it skipped, what it spent today — so the background analyst is
///      never a black box the user has to trust blindly.
///
/// Config is daemon-owned state, so every write round-trips through
/// `daemon.inbox.config.update` and the screen renders the value the daemon
/// *stored* (which is re-clamped), never the value it optimistically sent.
struct AIInboxSettingsView: View {
    @State private var model = AIInboxSettingsModel()

    /// Defaults to `true` to match `AIInboxSyncService.isEnabled`, which treats
    /// an absent value as enabled. Declaring the same default here keeps the
    /// switch from rendering "off" while the mirror is in fact running.
    @AppStorage(AIInboxSyncService.preferenceKey) private var cloudMirrorEnabled = true

    /// Same absent-means-enabled contract as `FleetSyncService.isEnabled`. The
    /// fleet mirror switch lives beside the inbox mirror switch deliberately:
    /// they are the two sealed off-device mirrors, and a user reasoning about
    /// "what leaves this Mac" should find them in one place.
    @AppStorage(FleetSyncService.preferenceKey) private var fleetCloudMirrorEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header

            if let unavailable = model.unavailableReason {
                unavailableBanner(unavailable)
            } else if model.isLoading {
                ProgressView("Checking daemon…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                enableSection
                if model.config.enabled {
                    Divider().background(DesignSystem.Colors.border)
                    egressSection
                    Divider().background(DesignSystem.Colors.border)
                    readingStyleSection
                    Divider().background(DesignSystem.Colors.border)
                    budgetSection
                    Divider().background(DesignSystem.Colors.border)
                    cadenceSection
                    Divider().background(DesignSystem.Colors.border)
                    sourcesSection
                    Divider().background(DesignSystem.Colors.border)
                    telemetrySection
                }
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .task { await model.load() }
        .accessibilityIdentifier(OBBAccessibilityID.settingsRow("ai-inbox"))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "tray.full")
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text("AI Inbox")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                if model.isSaving {
                    ProgressView().controlSize(.small)
                }
            }
            Text("A background analyst that reads your recent agent sessions, checks them against your workspace and GitHub, and tells you what needs attention.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsAnchor(SettingsAnchor.aiInboxOverview)
    }

    private func unavailableBanner(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignSystem.Colors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The AI Inbox is not available yet")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(reason)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button {
                Task { await model.load(forceTokenRefresh: true) }
            } label: {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Retry")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isLoading)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                .fill(DesignSystem.Colors.warning.opacity(0.10))
        )
    }

    // MARK: - Sections

    private var enableSection: some View {
        SettingsToggle(
            title: "Run the AI Inbox",
            subtitle: "Wakes every few minutes. When nothing has changed it does nothing and costs nothing.",
            isOn: model.binding(\.enabled) { config, value in config.with(enabled: value) }
        )
        .settingsAnchor(SettingsAnchor.aiInboxEnable)
    }

    private var egressSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("What leaves this Mac")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Picker("", selection: model.binding(\.egressMode) { config, value in
                config.with(egressMode: value)
            }) {
                Text("Nothing").tag(BurnBarInboxEgressMode.off)
                Text("Local only").tag(BurnBarInboxEgressMode.local)
                Text("Cloud models").tag(BurnBarInboxEgressMode.cloud)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(Self.egressExplanation(model.config.egressMode))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Plain-language consequences, not feature names. The user is deciding where
    /// their conversation text is allowed to go.
    static func egressExplanation(_ mode: BurnBarInboxEgressMode) -> String {
        switch mode {
        case .off:
            return "No conversation text leaves this Mac, ever. You still get every alert — the pattern detection is arithmetic, not AI — but the written summaries are plain rather than composed."
        case .local:
            return "Summaries are written by a model running on this machine or your local network (Ollama). Nothing reaches a cloud provider."
        case .cloud:
            return "Redacted excerpts may be sent to the configured providers to write summaries and double-check findings. Secrets are stripped before anything is sent, and an excerpt that still trips the scanner is withheld entirely."
        }
    }

    /// How the briefs are *written* — not what they are about.
    ///
    /// The usual failure of an analyst brief is not that it is wrong, it is
    /// that it is pitched at the wrong reader. A brief written for someone who
    /// already knows the internals is noise at 1am; the reverse is
    /// condescending. These two dials set the default; the "Plain English /
    /// Shorter / Go deeper" chips on each item re-pitch a single item without
    /// changing it.
    ///
    /// Each combination selects one of nine byte-stable prompt constants rather
    /// than interpolating a sentence, which is what keeps provider prompt
    /// caching (and its ~50x input discount) working across ticks.
    private var readingStyleSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("How briefs are written")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Picker("", selection: model.binding(\.briefRegister) { config, value in
                config.with(briefRegister: value)
            }) {
                Text("Plain English").tag(BurnBarInboxBriefRegister.plainEnglish)
                Text("Colleague").tag(BurnBarInboxBriefRegister.professional)
                Text("Expert").tag(BurnBarInboxBriefRegister.expert)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Reading level")

            Picker("", selection: model.binding(\.briefDetail) { config, value in
                config.with(briefDetail: value)
            }) {
                Text("Brief").tag(BurnBarInboxBriefDetail.brief)
                Text("Standard").tag(BurnBarInboxBriefDetail.standard)
                Text("Deep").tag(BurnBarInboxBriefDetail.deep)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("How much detail")

            Text(Self.readingStyleExplanation(
                register: model.config.briefRegister,
                detail: model.config.briefDetail
            ))
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says what will change in the writing, in the writing style being
    /// described — so the sentence itself is a sample of the setting.
    static func readingStyleExplanation(
        register: BurnBarInboxBriefRegister,
        detail: BurnBarInboxBriefDetail
    ) -> String {
        let voice: String
        switch register {
        case .plainEnglish:
            voice = "Short, everyday words. No jargon, no acronyms without saying what they mean."
        case .professional:
            voice = "Written for a colleague on this project — normal engineering vocabulary, no explaining the basics."
        case .expert:
            voice = "Assumes you know the internals. Names mechanisms directly and skips the preamble."
        }
        let depth: String
        switch detail {
        case .brief: depth = "Kept to the headline and the one thing to do about it."
        case .standard: depth = "A few sentences: what happened, why it matters, what follows."
        case .deep: depth = "Includes the mechanism and the knock-on consequences. Costs more per tick."
        }
        return voice + " " + depth
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Daily budget")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Text(model.config.dailyBudgetUSD > 0
                     ? String(format: "$%.2f", model.config.dailyBudgetUSD)
                     : "No limit")
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Slider(
                value: model.binding(\.dailyBudgetUSD) { config, value in
                    config.with(dailyBudgetUSD: value)
                },
                in: 0...10,
                step: 0.25
            )

            Text(model.config.dailyBudgetUSD > 0
                 ? "When the inbox reaches this, it stops writing summaries for the day and keeps detecting. Typical use lands well under a dollar."
                 : "No cap. The inbox will keep writing summaries regardless of spend.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let spend = model.todaySpendUSD {
                ProgressView(
                    value: model.config.dailyBudgetUSD > 0
                        ? min(spend / model.config.dailyBudgetUSD, 1)
                        : 0
                )
                .tint(spend >= model.config.dailyBudgetUSD && model.config.dailyBudgetUSD > 0
                      ? DesignSystem.Colors.warning
                      : DesignSystem.Colors.ember)
                Text(String(format: "Spent today: $%.4f", spend))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            SettingsToggle(
                title: "Count subscription spend",
                subtitle: "Off: the budget guards real API dollars only — calls covered by a flat plan (imputed value) run free. On: everything counts.",
                isOn: model.binding(\.budgetCountsSubscriptionSpend) { config, value in
                    config.with(budgetCountsSubscriptionSpend: value)
                }
            )
        }
    }

    private var cadenceSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Check every")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Text(Self.cadenceLabel(model.config.tickSeconds))
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Slider(
                value: Binding(
                    get: { Double(model.config.tickSeconds) },
                    set: { seconds in
                        model.update { $0.with(tickSeconds: Int(seconds)) }
                    }
                ),
                in: Double(BurnBarInboxConfig.minimumTickSeconds)...1_800,
                step: 60
            )

            Text("A check with nothing new costs nothing, so a shorter interval mostly means fresher alerts rather than more spend.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func cadenceLabel(_ seconds: Int) -> String {
        seconds < 120 ? "\(seconds)s" : "\(seconds / 60) min"
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsToggle(
                title: "Check GitHub",
                subtitle: "Uses the `gh` CLI you already signed in to, so OpenBurnBar stores no GitHub token of its own. Lets the inbox tell you whether promised work actually shipped.",
                isOn: model.binding(\.githubEnabled) { config, value in config.with(githubEnabled: value) }
            )

            SettingsToggle(
                title: "Notify me about urgent items",
                subtitle: "Only the top priority band, and at most once an hour for the same thing.",
                isOn: model.binding(\.notifyOnP1) { config, value in config.with(notifyOnP1: value) }
            )

            // Not daemon config: the mirror runs in the app (the only process
            // with Firebase auth), so this is a local preference rather than a
            // `daemon.inbox.config.update` round trip. It is surfaced here
            // because it is the one inbox switch with an off-device
            // consequence, and a privacy control the user cannot find is not a
            // control.
            SettingsToggle(
                title: "Sync the inbox to my phone",
                subtitle: """
                    Mirrors items to your other signed-in devices so you can read them while this Mac is asleep. \
                    Titles, summaries, and evidence are encrypted before they leave — only routing metadata \
                    (kind, priority, timestamps) is readable by the server. Turn this off to keep the inbox on this Mac only.
                    """,
                isOn: $cloudMirrorEnabled
            )

            // Also a local preference rather than daemon config, for the same
            // reason as the inbox mirror above: the publisher runs in the app,
            // the only process with Firebase auth.
            SettingsToggle(
                title: "Sync the Agent Fleet to my phone",
                subtitle: """
                    Mirrors the fleet dashboard to your other signed-in devices so you can check on your agents \
                    while this Mac is asleep. Agent names, tasks, repos, and machine stats are encrypted before \
                    they leave — only timestamps are readable by the server. The phone view is read-only: \
                    orchestrator controls stay on this Mac. Turn this off to keep the fleet on this Mac only.
                    """,
                isOn: $fleetCloudMirrorEnabled
            )
        }
    }

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Recent checks")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button { Task { await model.runNow() } } label: {
                    Text(model.isRunningNow ? "Analyzing…" : "Analyze now")
                        .font(DesignSystem.Typography.tiny)
                }
                .buttonStyle(.bordered)
                .disabled(model.isRunningNow)
            }

            if model.runs.isEmpty {
                Text("No checks yet. The first one runs within the interval above.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } else {
                // The skip ratio is the number that proves the cost story, so it
                // gets stated outright rather than left to be inferred.
                Text(model.skipSummary)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                ForEach(model.runs.prefix(6)) { run in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Circle()
                            .fill(Self.runTint(run))
                            .frame(width: 6, height: 6)
                        Text(run.startedAt, style: .time)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(Self.runLabel(run))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Spacer(minLength: 0)
                        if run.costUSD > 0 {
                            Text(String(format: "$%.4f", run.costUSD))
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                }
            }
        }
    }

    static func runTint(_ run: BurnBarInboxRunTelemetry) -> Color {
        switch run.gateResult {
        case .skippedUnchanged, .skippedDisabled: return DesignSystem.Colors.textMuted
        case .failed: return DesignSystem.Colors.warning
        case .localChanged, .remotePhase, .forced: return DesignSystem.Colors.ember
        }
    }

    static func runLabel(_ run: BurnBarInboxRunTelemetry) -> String {
        switch run.gateResult {
        case .skippedUnchanged: return "nothing had changed"
        case .skippedDisabled: return "turned off"
        case .failed: return run.error.map { "failed — \($0.prefix(60))" } ?? "failed"
        case .localChanged, .remotePhase, .forced:
            var parts: [String] = []
            if run.itemsNew > 0 { parts.append("\(run.itemsNew) new") }
            if run.itemsUpdated > 0 { parts.append("\(run.itemsUpdated) updated") }
            if run.itemsResolved > 0 { parts.append("\(run.itemsResolved) resolved") }
            if run.llmCalls == 0 {
                parts.append(
                    run.egressMode.allowsModelCalls
                        ? "rule-based (model skipped — budget?)"
                        : "rule-based (egress off)"
                )
            }
            return parts.isEmpty ? "analyzed, nothing to report" : parts.joined(separator: ", ")
        }
    }
}

// MARK: - Model

/// Owns the daemon round trips for the settings screen.
@Observable
@MainActor
final class AIInboxSettingsModel {
    private(set) var config = BurnBarInboxConfig()
    private(set) var runs: [BurnBarInboxRunTelemetry] = []
    private(set) var todaySpendUSD: Double?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isRunningNow = false
    private(set) var unavailableReason: String?
    var errorMessage: String?

    private var saveTask: Task<Void, Never>?

    func load(forceTokenRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            if forceTokenRefresh {
                OpenBurnBarDaemonSocketClient.cacheDaemonSocketAuthToken(nil)
            }
            let socketURL = try Self.socketURL()
            // Blocking POSIX socket I/O — never on the main actor (beachball).
            let loaded = try await Self.rpc {
                try OpenBurnBarDaemonSocketClient.inboxConfiguration(at: socketURL)
            }
            config = loaded
            unavailableReason = nil
            await loadTelemetry()
        } catch {
            unavailableReason = Self.friendlyUnavailable(error)
        }
    }

    func loadTelemetry() async {
        guard let socketURL = try? Self.socketURL() else { return }
        let response = try? await Self.rpc {
            try OpenBurnBarDaemonSocketClient.inboxRuns(at: socketURL)
        }
        guard let response else { return }
        runs = response.runs
        todaySpendUSD = response.todaySpendUSD
    }

    /// Fraction of recent checks that cost nothing — the honest answer to
    /// "is this thing burning money in the background?".
    var skipSummary: String {
        let skipped = runs.filter {
            $0.gateResult == .skippedUnchanged || $0.gateResult == .skippedDisabled
        }.count
        guard runs.isEmpty == false else { return "" }
        let percent = Int((Double(skipped) / Double(runs.count) * 100).rounded())
        let spend = runs.reduce(0.0) { $0 + $1.costUSD }
        return "\(percent)% of the last \(runs.count) checks found nothing to do" +
            (spend > 0 ? String(format: " · $%.4f total", spend) : " · no spend")
    }

    /// A binding that writes through the daemon and renders what it stored.
    func binding<Value>(
        _ keyPath: KeyPath<BurnBarInboxConfig, Value>,
        apply: @escaping (BurnBarInboxConfig, Value) -> BurnBarInboxConfig
    ) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { newValue in self.update { apply($0, newValue) } }
        )
    }

    func update(_ transform: (BurnBarInboxConfig) -> BurnBarInboxConfig) {
        let next = transform(config)
        config = next
        // Coalesce rapid edits (a slider drag is dozens of sets) into one write.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.persist(next)
        }
    }

    private func persist(_ next: BurnBarInboxConfig) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let socketURL = try Self.socketURL()
            // Render what the daemon stored, not what we sent: values are clamped
            // on write, so the two can legitimately differ.
            config = try await Self.rpc {
                try OpenBurnBarDaemonSocketClient.updateInboxConfiguration(next, at: socketURL)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    func runNow() async {
        isRunningNow = true
        defer { isRunningNow = false }
        do {
            let socketURL = try Self.socketURL()
            let response = try await Self.rpc {
                try OpenBurnBarDaemonSocketClient.runInboxNow(force: true, at: socketURL)
            }
            if response.accepted == false {
                errorMessage = response.reason
            } else {
                errorMessage = nil
            }
            await loadTelemetry()
        } catch {
            errorMessage = "Could not start a check: \(error.localizedDescription)"
        }
    }

    private static func socketURL() throws -> URL {
        OpenBurnBarDaemonRuntimePaths.live().socketURL
    }

    /// Hop blocking Unix-socket I/O onto a cooperative pool thread. `daemonRPC`
    /// is also nonisolated, but `Task.detached` makes the off-main guarantee
    /// explicit for Settings (where a 30s socket timeout would beachball).
    private static func rpc<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }

    static func friendlyUnavailable(_ error: Error) -> String {
        let description = error.localizedDescription
        let lowered = description.lowercased()
        if description.contains("OPENBURNBAR_INDEX_DATABASE_PATH") {
            return "The OpenBurnBar daemon is running without an index database, so it cannot analyze anything yet."
        }
        if lowered.contains("waiting for the index database") {
            return "The index database has not been created yet. Keep OpenBurnBar open until the first scan finishes, then tap Retry."
        }
        if lowered.contains("sqlcipher")
            || lowered.contains("cipher")
            || lowered.contains("encryption key")
            || lowered.contains("file is not a database")
            || lowered.contains("file is encrypted") {
            return "The daemon could not unlock the encrypted index database. Unlock this Mac, confirm OpenBurnBar can access the Keychain, then tap Retry. If you installed a local Debug build, rebuild/re-sign the daemon so it can read the same Keychain item as the app."
        }
        if lowered.contains("busy") || lowered.contains("locked") {
            return "The index database is busy (another OpenBurnBar component is writing). Wait a moment and tap Retry."
        }
        if lowered.contains("unauthorized") || lowered.contains("auth token") {
            return "The app could not authenticate to the daemon. Open Settings → Daemon and use Repair, then tap Retry."
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return "The daemon did not answer in time. It may be overloaded — wait a moment and tap Retry."
        }
        if lowered.contains("connection refused") || lowered.contains("no such file") || lowered.contains("connect failed") {
            return "The OpenBurnBar daemon is not running. Open Settings → Daemon and start or repair it, then tap Retry."
        }
        if lowered.contains("empty response") {
            return "The daemon closed the connection without a reply (often a code-signature mismatch). Repair the daemon from Settings → Daemon, then tap Retry."
        }
        // Prefer the daemon's concrete bootstrap reason over a generic unreachable blurb.
        if lowered.contains("ai inbox") || lowered.contains("sqlite") || lowered.contains("database") {
            return description
        }
        return "The OpenBurnBar daemon is not reachable right now. Start or repair it from Settings → Daemon, then tap Retry."
    }
}

// MARK: - Config mutation helpers

extension BurnBarInboxConfig {
    /// `BurnBarInboxConfig` is immutable (every value is clamped in `init`), so
    /// the settings screen edits it by rebuilding. These wrappers keep the call
    /// sites readable and guarantee the clamps always run.
    ///
    /// Every field of `BurnBarInboxConfig` must appear below, whether or not it
    /// is editable here — a field that is merely *omitted* is silently reset to
    /// its default on the next unrelated toggle. That has now happened four
    /// times (`budgetCountsSubscriptionSpend`, the three Founder Lens fields,
    /// and the two reading-register fields), so it is no longer left to
    /// vigilance: `BurnBarInboxConfigWithTests.testWithPreservesEveryUnrelatedField`
    /// walks the struct reflectively and fails the moment a new field is added
    /// without being threaded through here.
    func with(
        enabled: Bool? = nil,
        egressMode: BurnBarInboxEgressMode? = nil,
        tickSeconds: Int? = nil,
        dailyBudgetUSD: Double? = nil,
        githubEnabled: Bool? = nil,
        notifyOnP1: Bool? = nil,
        budgetCountsSubscriptionSpend: Bool? = nil,
        briefDetail: BurnBarInboxBriefDetail? = nil,
        briefRegister: BurnBarInboxBriefRegister? = nil
    ) -> BurnBarInboxConfig {
        BurnBarInboxConfig(
            enabled: enabled ?? self.enabled,
            egressMode: egressMode ?? self.egressMode,
            tickSeconds: tickSeconds ?? self.tickSeconds,
            remotePhaseEveryNTicks: remotePhaseEveryNTicks,
            dailyBudgetUSD: dailyBudgetUSD ?? self.dailyBudgetUSD,
            maxVerifierCallsPerTick: maxVerifierCallsPerTick,
            perTickPromptTokenCap: perTickPromptTokenCap,
            analystProviderID: analystProviderID,
            analystModel: analystModel,
            verifierProviderID: verifierProviderID,
            verifierModel: verifierModel,
            githubEnabled: githubEnabled ?? self.githubEnabled,
            notifyOnP1: notifyOnP1 ?? self.notifyOnP1,
            lookbackMinutes: lookbackMinutes,
            // Founder Lens fields must survive unrelated edits — omitting them
            // here silently reset a disabled lens or a lowered reply budget to
            // defaults on every settings change.
            founderLensEnabled: founderLensEnabled,
            perReplyBudgetUSD: perReplyBudgetUSD,
            maxThreadTurns: maxThreadTurns,
            budgetCountsSubscriptionSpend: budgetCountsSubscriptionSpend
                ?? self.budgetCountsSubscriptionSpend,
            briefDetail: briefDetail ?? self.briefDetail,
            briefRegister: briefRegister ?? self.briefRegister
        )
    }
}

/// Top-level Settings destination for AI Inbox (sidebar tab + search deep link).
/// Kept as a thin shell so Indexing can also push the same route without nesting
/// another ScrollView around the content view.
struct AIInboxSettingsRootView: View {
    var body: some View {
        SettingsDeepLinkScrollContainer(route: .aiInboxRoot) { _ in
            ScrollView {
                GlassCard {
                    AIInboxSettingsView()
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DesignSystem.Colors.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
