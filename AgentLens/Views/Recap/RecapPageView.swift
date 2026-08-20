import AppKit
import OpenBurnBarRecap
import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarUI

// MARK: - Recap Page
//
// The full-page monthly recap. Mirrors the Charts page's shell — scroll view,
// `Spacing.xl` gutters, clamped to 1180pt — because that is the page template
// this app already uses, and a recap that framed itself differently would read
// as a bolt-on.
//
// The AI switch follows the same contract as `chartsPage.llmInsightsEnabled`:
// opt-in, and the footnote always names where the summary went.

struct RecapPageView: View {

    let dataStore: DataStore
    let settingsManager: SettingsManager
    let chatController: ChatSessionController

    @State private var environment: MacRecapEnvironment?
    @State private var setupError: String?
    @AppStorage(MacRecapEnvironment.aiToggleKey) private var editorialEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header
                content
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .recapScrollEdgeSoftening()
        .accessibilityIdentifier(OBBAccessibilityID.recapPage)
        .task { await setUpIfNeeded() }
        .onDisappear { environment?.cancel() }
        .onChange(of: editorialEnabled) {
            // Turning the switch on should visibly do something to the month
            // being looked at, not only to months built later.
            environment?.load(forceRegenerate: false)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recap")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("A month of your AI work, read back to you")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer(minLength: DesignSystem.Spacing.lg)

            if let environment {
                if environment.isPolishing {
                    polishingIndicator
                }
                monthPicker(environment)
            }
            editorialToggle
        }
    }

    private var polishingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Writing…")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .transition(.opacity)
    }

    private func monthPicker(_ environment: MacRecapEnvironment) -> some View {
        Picker("Month", selection: Binding(
            get: { environment.selectedMonth },
            set: { environment.select($0) }
        )) {
            ForEach(environment.availableMonths) { month in
                Text(month.displayLabel()).tag(month)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
        .accessibilityIdentifier(OBBAccessibilityID.recapMonthPicker)
    }

    private var editorialToggle: some View {
        Toggle(isOn: $editorialEnabled) {
            Label("Let AI write it", systemImage: "sparkles")
                .font(DesignSystem.Typography.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help("Your numbers stay on this device either way — only the wording is written by a model.")
        .accessibilityIdentifier(OBBAccessibilityID.recapEditorialToggle)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let setupError {
            RecapEmptyStateView(reason: .failed(setupError))
        } else if let environment {
            switch environment.phase {
            case .idle, .building, .ready:
                if let recap = environment.recap {
                    deck(recap, environment: environment)
                } else {
                    buildingPlaceholder
                }
            case let .notEnoughData(window):
                RecapEmptyStateView(reason: .notEnoughActivity(window))
            case let .failed(message):
                RecapEmptyStateView(reason: .failed(message))
            }
        } else {
            buildingPlaceholder
        }
    }

    private func deck(_ recap: MonthlyRecap, environment: MacRecapEnvironment) -> some View {
        RecapDeckView(
            recap: recap,
            onShareCard: { card in export(card: card, window: recap.window) },
            onShareRecap: { export(recap: recap) }
        )
        .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: recap.isVoiceAuthored)
    }

    private var buildingPlaceholder: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Reading your month…")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: Setup

    private func setUpIfNeeded() async {
        guard environment == nil, setupError == nil else { return }
        do {
            let created = try MacRecapEnvironment(
                dataStore: dataStore,
                bridge: chatController.cliBridge,
                enabledBackends: { settingsManager.enabledChatBackends }
            )
            environment = created
            await created.refreshAvailableMonths()
            created.load()
        } catch {
            setupError = error.localizedDescription
        }
    }

    // MARK: Export

    private func export(card: RecapCard, window: RecapWindow) {
        let renderer = RecapShareCardRenderer()
        guard let data = renderer.png(card: card, window: window) else { return }
        save(data, suggested: renderer.suggestedFilename(for: window, cardID: card.id))
    }

    private func export(recap: MonthlyRecap) {
        let renderer = RecapShareCardRenderer()
        guard let data = renderer.png(recap: recap) else { return }
        save(data, suggested: renderer.suggestedFilename(for: recap.window))
    }

    /// `NSSavePanel`, matching how every other macOS export in this app works.
    private func save(_ data: Data, suggested name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}
