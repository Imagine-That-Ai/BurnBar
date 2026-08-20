import OpenBurnBarCore
import SwiftUI

// MARK: - Ask (storage id `constellation`)
//
// For the conversational thinker — the person who would rather type "why did
// Claude cost so much on Tuesday" than find the chart that answers it.
//
// Thesis: the question comes first and is the largest thing on the page.
// Everything below it is framed as *context for the question you are about to
// ask*, not as a report. The layout is mostly empty on purpose: an empty field
// invites a sentence, a dense grid invites scanning.
//
// Primary axis: vertical, centred, narrow. Dominant element: the ask field.
// Density: the second lowest, after Focus.
//
// Enforced rule: **the ask field is the first and largest element.** Nothing
// above it but the update banner, and nothing below it renders type larger than
// `Typography.headline`. Numbers here are inline in sentences and rows, never
// hero values — a number set in 40pt type is an answer, and this layout's job
// is to collect the question.

extension DashboardView {
    var constellationLayout: some View {
        conceptCanvas(
            maxWidth: 760,
            spacing: DesignSystem.Spacing.xl,
            alignment: .center,
            gutter: DesignSystem.Spacing.xxl
        ) {
            conceptUpdateBanner
            askField
            askSuggestions
            askContext
            conceptMoreDrawer
        }
    }

    // MARK: The question

    private var askField: some View {
        Button {
            Analytics.shared.track(.dashboardLaneCardOpened, ["lane": "ask_field"])
            withAnimation(DesignSystem.Animation.standard) { chatPanelOpen = true }
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Text("ASK HERMES")
                        .font(DesignSystem.Typography.tiny)
                        .tracking(1.3)
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Spacer(minLength: 0)
                    Text("⌘K")
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(dashboardSectionInk.subtle)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(dashboardSectionInk.hairline))
                }

                Text(askPlaceholder)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(dashboardSectionInk.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .backdropLegiblePlate(
                accent: DesignSystem.Colors.ember,
                washOpacity: 0.10,
                strokeColor: DesignSystem.Colors.ember.opacity(0.32),
                strokeWidth: 1,
                cornerRadius: DesignSystem.Radius.xl
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Hermes about your spend")
        .accessibilityHint("Opens the chat panel")
    }

    /// Reflects the data actually present, so the invitation is answerable.
    private var askPlaceholder: String {
        guard let leader = topProviderSummary else {
            return "Ask anything about your spend once sessions start landing…"
        }
        return "Ask about \(leader.provider.displayName), a model, a project, or any of the \(dataStore.totalUsageSessionCount.formatted()) sessions on this machine…"
    }

    // MARK: Suggested questions

    private var askSuggestions: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSystem.Spacing.sm)],
            spacing: DesignSystem.Spacing.sm
        ) {
            ForEach(askSuggestedQuestions, id: \.self) { question in
                askSuggestionChip(question)
            }
        }
    }

    /// Grounded in the current window rather than hardcoded, so a suggestion is
    /// never about a provider the user does not run.
    private var askSuggestedQuestions: [String] {
        var questions = ["Where did my spend go this window?"]
        if let leader = topProviderSummary {
            questions.append("Why is \(leader.provider.displayName) my biggest line?")
        }
        if let model = dashboardModelSummaries.first {
            questions.append("Is \(model.displayName) worth what it costs?")
        }
        if dashboardUsageWindow.cacheEfficiency.hasSignal {
            questions.append("How do I raise my cache hit rate?")
        }
        return questions
    }

    private func askSuggestionChip(_ question: String) -> some View {
        Button {
            Analytics.shared.track(.dashboardLaneCardOpened, ["lane": "ask_suggestion"])
            withAnimation(DesignSystem.Animation.standard) { chatPanelOpen = true }
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(dashboardSectionInk.icon)
                Text(question)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(dashboardSectionInk.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .backdropLegiblePlate(
                accent: DesignSystem.Colors.ember,
                washOpacity: 0.03,
                strokeColor: DesignSystem.Colors.border.opacity(0.34),
                cornerRadius: DesignSystem.Radius.md
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(question)
    }

    // MARK: What you'd be asking about

    /// One quiet section naming the material a question would land on. Rows, and
    /// deliberately capped, because this is a footnote to the field above it.
    private var askContext: some View {
        DashboardSection(
            "What you're asking about",
            density: .compact,
            emphasis: .quiet
        ) {
            VStack(spacing: 0) {
                DashboardSectionMetric(
                    label: "Window",
                    value: totalCostForTimeRange.formatAsCost(),
                    caption: selectedTimeRange.displayName
                )
                .padding(.vertical, 7)
                DashboardSectionRule()
                DashboardSectionMetric(
                    label: "Sessions on this machine",
                    value: dataStore.totalUsageSessionCount.formatted()
                )
                .padding(.vertical, 7)
                DashboardSectionRule()
                DashboardRankedTable(
                    items: conceptProviderRows,
                    showsRank: false,
                    showsShare: false,
                    limit: 4,
                    emptyMessage: "No provider activity yet.",
                    onSelect: { item in
                        guard let provider = item.provider else { return }
                        conceptOpenProvider(provider, lane: "ask_provider")
                    }
                )
            }
        }
    }
}
