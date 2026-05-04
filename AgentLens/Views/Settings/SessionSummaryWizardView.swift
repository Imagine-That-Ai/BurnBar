import SwiftUI

// MARK: - Session Summary Wizard View

/// Multi-step wizard for configuring session summarization settings
struct SessionSummaryWizardView: View {
    @Binding var config: SummaryConfig
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var currentStep: WizardStep = .model
    @State private var localConfig: SummaryConfig

    init(config: Binding<SummaryConfig>, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self._config = config
        self.onComplete = onComplete
        self.onCancel = onCancel
        self._localConfig = State(initialValue: config.wrappedValue)
    }

    enum WizardStep: Int {
        case model
        case topics
        case tone
        case review

        static var orderedSteps: [WizardStep] {
            [.model, .topics, .tone, .review]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            wizardHeader

            Divider().background(DesignSystem.Colors.border)

            // Content
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    stepContent
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Divider().background(DesignSystem.Colors.border)

            // Navigation
            wizardNavigation
        }
        .frame(width: 520)
        .frame(minHeight: 480)
        .background(DesignSystem.Colors.background)
    }

    // MARK: - Header

    @ViewBuilder
    private var wizardHeader: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack {
                ForEach(WizardStep.orderedSteps, id: \.rawValue) { step in
                    stepIndicator(step)
                    if step != WizardStep.orderedSteps.last {
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.lg)

            Text(stepTitle)
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text(stepDescription)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.bottom, DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private func stepIndicator(_ step: WizardStep) -> some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            ZStack {
                Circle()
                    .fill(stepStateColor(step))
                    .frame(width: 28, height: 28)

                if step.rawValue < currentStep.rawValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.bold)
                        .foregroundStyle(step == currentStep ? .white : DesignSystem.Colors.textSecondary)
                }
            }

            Text(step.shortTitle)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(step == currentStep ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
        }
        .frame(width: 80)
    }

    private func stepStateColor(_ step: WizardStep) -> Color {
        if step.rawValue < currentStep.rawValue {
            return DesignSystem.Colors.success
        } else if step == currentStep {
            return DesignSystem.Colors.blaze
        } else {
            return DesignSystem.Colors.surface
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .model:
            modelSelectionStep
        case .topics:
            topicSelectionStep
        case .tone:
            toneSelectionStep
        case .review:
            reviewStep
        }
    }

    @ViewBuilder
    private var modelSelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Choose a summarization model")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Models affect summary quality and generation speed.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: DesignSystem.Spacing.sm) {
                modelOption(.quality, title: "Quality", description: "Detailed, high-quality summaries", icon: "star.fill", badge: "Best")
                modelOption(.balanced, title: "Balanced", description: "Good quality at reasonable speed", icon: "scalemass.fill", badge: nil)
                modelOption(.fast, title: "Fast", description: "Quick summaries, lower detail", icon: "bolt.fill", badge: nil)
            }
        }
    }

    @ViewBuilder
    private func modelOption(_ model: SummaryModelType, title: String, description: String, icon: String, badge: String?) -> some View {
        Button {
            localConfig.modelType = model
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(localConfig.modelType == model ? DesignSystem.Colors.blaze : DesignSystem.Colors.textMuted)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if let badge = badge {
                            Text(badge)
                                .font(DesignSystem.Typography.tiny)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DesignSystem.Colors.blaze.opacity(0.15))
                                .foregroundStyle(DesignSystem.Colors.blaze)
                                .clipShape(Capsule())
                        }
                    }
                    Text(description)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                if localConfig.modelType == model {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.blaze)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(localConfig.modelType == model ? DesignSystem.Colors.blaze.opacity(0.1) : DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(localConfig.modelType == model ? DesignSystem.Colors.blaze : DesignSystem.Colors.border, lineWidth: localConfig.modelType == model ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var topicSelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("What topics should summaries focus on?")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Select the topics most relevant to your workflow.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: DesignSystem.Spacing.sm) {
                topicToggle(.code, title: "Code Changes", description: "Focus on code modifications and technical details", icon: "chevron.left.forwardslash.chevron.right")
                topicToggle(.decisions, title: "Decisions", description: "Key architectural and design decisions", icon: "checkmark.seal.fill")
                topicToggle(.errors, title: "Errors & Fixes", description: "Bugs encountered and their resolutions", icon: "exclamationmark.triangle.fill")
                topicToggle(.questions, title: "Open Questions", description: "Items requiring follow-up or research", icon: "questionmark.circle.fill")
                topicToggle(.files, title: "Files Modified", description: "List of created, edited, or deleted files", icon: "doc.fill")
            }
        }
    }

    @ViewBuilder
    private func topicToggle(_ topic: SummaryTopic, title: String, description: String, icon: String) -> some View {
        Button {
            if localConfig.topics.contains(topic) {
                localConfig.topics.remove(topic)
            } else {
                localConfig.topics.insert(topic)
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(localConfig.topics.contains(topic) ? DesignSystem.Colors.blaze : DesignSystem.Colors.textMuted)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(description)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Image(systemName: localConfig.topics.contains(topic) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(localConfig.topics.contains(topic) ? DesignSystem.Colors.blaze : DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.md)
            .background(localConfig.topics.contains(topic) ? DesignSystem.Colors.blaze.opacity(0.1) : DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(localConfig.topics.contains(topic) ? DesignSystem.Colors.blaze : DesignSystem.Colors.border, lineWidth: localConfig.topics.contains(topic) ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var toneSelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Choose a summary tone")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("The tone affects how summaries are written.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: DesignSystem.Spacing.sm) {
                toneOption(.concise, title: "Concise", description: "Brief, to-the-point summaries", icon: "text.alignleft")
                toneOption(.detailed, title: "Detailed", description: "Comprehensive with full context", icon: "text.alignleft")
                toneOption(.technical, title: "Technical", description: "Focus on technical details", icon: "hammer.fill")
                toneOption(.narrative, title: "Narrative", description: "Story-like with explanations", icon: "book.fill")
            }
        }
    }

    @ViewBuilder
    private func toneOption(_ tone: SummaryTone, title: String, description: String, icon: String) -> some View {
        Button {
            localConfig.tone = tone
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(localConfig.tone == tone ? DesignSystem.Colors.blaze : DesignSystem.Colors.textMuted)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(description)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                if localConfig.tone == tone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.blaze)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(localConfig.tone == tone ? DesignSystem.Colors.blaze.opacity(0.1) : DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(localConfig.tone == tone ? DesignSystem.Colors.blaze : DesignSystem.Colors.border, lineWidth: localConfig.tone == tone ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("Review Your Settings")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            VStack(spacing: DesignSystem.Spacing.md) {
                reviewRow("Model", value: localConfig.modelType.displayName)
                Divider().background(DesignSystem.Colors.border)
                reviewRow("Topics", value: localConfig.topics.map { $0.displayName }.joined(separator: ", "))
                Divider().background(DesignSystem.Colors.border)
                reviewRow("Tone", value: localConfig.tone.displayName)
            }
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5))

            Text("You can always change these settings later in the app preferences.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    private func reviewRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .padding(DesignSystem.Spacing.md)
    }

    // MARK: - Navigation

    @ViewBuilder
    private var wizardNavigation: some View {
        HStack {
            Button("Back") {
                if let prevStep = WizardStep(rawValue: currentStep.rawValue - 1) {
                    withAnimation { currentStep = prevStep }
                }
            }
            .buttonStyle(.bordered)
            .disabled(currentStep == .model)

            Spacer()

            Button("Cancel") { onCancel() }
                .buttonStyle(.bordered)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            if currentStep == .review {
                Button("Complete") {
                    config = localConfig
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
            } else {
                Button("Next") {
                    if let nextStep = WizardStep(rawValue: currentStep.rawValue + 1) {
                        withAnimation { currentStep = nextStep }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

    // MARK: - Step Properties

    private var stepTitle: String {
        switch currentStep {
        case .model: return "Select Model"
        case .topics: return "Choose Topics"
        case .tone: return "Set Tone"
        case .review: return "Review"
        }
    }

    private var stepDescription: String {
        switch currentStep {
        case .model: return "Choose a model that balances quality and speed"
        case .topics: return "Select what aspects to focus on in summaries"
        case .tone: return "Choose how formal or casual summaries should be"
        case .review: return "Confirm your summarization settings"
        }
    }
}

// MARK: - Supporting Types

enum SummaryModelType {
    case quality
    case balanced
    case fast

    var displayName: String {
        switch self {
        case .quality: return "Quality"
        case .balanced: return "Balanced"
        case .fast: return "Fast"
        }
    }
}

enum SummaryTopic: Hashable {
    case code
    case decisions
    case errors
    case questions
    case files

    var displayName: String {
        switch self {
        case .code: return "Code"
        case .decisions: return "Decisions"
        case .errors: return "Errors"
        case .questions: return "Questions"
        case .files: return "Files"
        }
    }
}

enum SummaryTone {
    case concise
    case detailed
    case technical
    case narrative

    var displayName: String {
        switch self {
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .technical: return "Technical"
        case .narrative: return "Narrative"
        }
    }
}

struct SummaryConfig {
    var modelType: SummaryModelType
    var topics: Set<SummaryTopic>
    var tone: SummaryTone

    init(
        modelType: SummaryModelType = .balanced,
        topics: Set<SummaryTopic>? = nil,
        tone: SummaryTone = .concise
    ) {
        self.modelType = modelType
        self.topics = topics ?? SummaryTopic.defaultTopics()
        self.tone = tone
    }
}

private extension SummaryTopic {
    static func defaultTopics() -> Set<SummaryTopic> {
        var topics = Set<SummaryTopic>()
        topics.insert(.code)
        topics.insert(.decisions)
        topics.insert(.errors)
        return topics
    }
}

extension SessionSummaryWizardView.WizardStep {
    var shortTitle: String {
        switch self {
        case .model: return "Model"
        case .topics: return "Topics"
        case .tone: return "Tone"
        case .review: return "Review"
        }
    }
}
