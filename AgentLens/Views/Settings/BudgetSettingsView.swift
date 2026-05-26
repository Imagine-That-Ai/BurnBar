import SwiftUI
import OpenBurnBarCore

// MARK: - Budget Settings landing

struct BudgetSettingsView: View {
    @Bindable var budgetSettings: BudgetSettings
    @State private var showingAddSheet: AddRuleScope?

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .alertsRoot) { _ in
            List {
                introSection
                globalSection
                credentialSection
                projectSection
                eventsSection
                reconciliationSection
            }
            .listStyle(.inset)
        }
        .navigationTitle("Budgets")
        .sheet(item: $showingAddSheet) { scope in
            BudgetRuleEditorSheet(
                budgetSettings: budgetSettings,
                rule: BudgetRule(
                    scope: scope.scope,
                    amountUSD: 50,
                    period: .month
                )
            )
        }
    }

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spending limits enforced locally.")
                    .font(.headline)
                Text("Per-usage credentials (Anthropic / OpenAI API keys, OpenRouter, etc.) get hard 402 blocks when a rule is exceeded. Subscription credentials (Claude Pro, bundled CLI plans) are exempt — they cost flat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Global section

    private var globalSection: some View {
        Section {
            ForEach(budgetSettings.globalRules) { rule in
                NavigationLink {
                    BudgetRuleEditorView(budgetSettings: budgetSettings, rule: rule)
                } label: {
                    BudgetRuleRow(rule: rule)
                }
            }
            if budgetSettings.globalRules.isEmpty {
                Button {
                    showingAddSheet = .global
                } label: {
                    Label("Add global cap", systemImage: "plus.circle.fill")
                }
            } else {
                Button {
                    showingAddSheet = .global
                } label: {
                    Label("Add another", systemImage: "plus")
                        .font(.caption)
                }
            }
        } header: {
            Text("Global cap")
        } footer: {
            Text("A single ceiling across every per-usage credential. The most permissive global rule wins.")
                .font(.caption2)
        }
    }

    // MARK: - Credential section

    private var credentialSection: some View {
        Section {
            ForEach(budgetSettings.credentialRules) { rule in
                NavigationLink {
                    BudgetRuleEditorView(budgetSettings: budgetSettings, rule: rule)
                } label: {
                    BudgetRuleRow(rule: rule)
                }
            }
            Button {
                showingAddSheet = .credential
            } label: {
                Label(budgetSettings.credentialRules.isEmpty ? "Add per-credential limit" : "Add another", systemImage: budgetSettings.credentialRules.isEmpty ? "plus.circle.fill" : "plus")
            }
        } header: {
            Text("Per credential / API key")
        } footer: {
            Text("Hard-blocks a specific API key (Anthropic Console, OpenAI, OpenRouter, etc.). Use this when one project should not be allowed to drain your monthly OpenAI budget.")
                .font(.caption2)
        }
    }

    // MARK: - Project section

    private var projectSection: some View {
        Section {
            ForEach(budgetSettings.projectRules) { rule in
                NavigationLink {
                    BudgetRuleEditorView(budgetSettings: budgetSettings, rule: rule)
                } label: {
                    BudgetRuleRow(rule: rule)
                }
            }
            Button {
                showingAddSheet = .project
            } label: {
                Label(budgetSettings.projectRules.isEmpty ? "Add per-project limit" : "Add another", systemImage: budgetSettings.projectRules.isEmpty ? "plus.circle.fill" : "plus")
            }
        } header: {
            Text("Per project")
        } footer: {
            Text("Cap a single project's monthly burn. Names match the project labels rendered in the Project Ranking lane.")
                .font(.caption2)
        }
    }

    // MARK: - Events footer

    @ViewBuilder
    private var eventsSection: some View {
        let recent = budgetSettings.recentEvents(limit: 8)
        if !recent.isEmpty {
            Section {
                ForEach(recent) { event in
                    BudgetEventRow(event: event)
                }
            } header: {
                Text("Recent activity")
            } footer: {
                Text("Audit log of warnings, blocks, overrides, and rule changes.")
                    .font(.caption2)
            }
        }
    }

    // MARK: - Reconciliation footer

    private var reconciliationSection: some View {
        Section {
            HStack {
                Label("Billing API reconciliation compares local-pricing spend against Anthropic / OpenAI / OpenRouter billing APIs. Drift > 5% is flagged in the audit log above.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
            }
        } header: {
            Text("Reconciliation")
        }
    }
}

// MARK: - Add rule scope picker

private enum AddRuleScope: String, Identifiable, CaseIterable {
    case global
    case credential
    case project

    var id: String { rawValue }

    var scope: BudgetRuleScope {
        switch self {
        case .global: return .global
        case .credential: return .credential
        case .project: return .project
        }
    }
}

// MARK: - Row

struct BudgetRuleRow: View {
    let rule: BudgetRule

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: scopeIcon)
                .foregroundStyle(scopeTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayLabel)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("$\(rule.amountUSD, specifier: "%.2f")")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text(periodLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var scopeIcon: String {
        switch rule.scope {
        case .global: return "globe"
        case .credential: return "key.fill"
        case .project: return "folder.fill"
        case .organization: return "building.2.fill"
        }
    }

    private var scopeTint: Color {
        switch rule.scope {
        case .global: return .blue
        case .credential: return .orange
        case .project: return .green
        case .organization: return .purple
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(behaviorLabel)
        if rule.isPaused() { parts.append("paused") }
        if !rule.isEnabled { parts.append("disabled") }
        return parts.joined(separator: " · ")
    }

    private var behaviorLabel: String {
        switch rule.behavior {
        case .warnThenBlock: return "warn then block"
        case .hardBlock: return "hard block"
        case .warnOnly: return "warn only"
        case .hardBlockWithFallback: return "block + failover"
        }
    }

    private var periodLabel: String {
        switch rule.period {
        case .day: return "per day"
        case .week: return "per week"
        case .month: return "per month"
        case .allTime: return "all time"
        }
    }
}

// MARK: - Event row

struct BudgetEventRow: View {
    let event: BudgetEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(kindLabel)
                    .font(.subheadline.weight(.semibold))
                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if event.limitAtEvent > 0 {
                Text("$\(event.amountAtEvent, specifier: "%.2f") / $\(event.limitAtEvent, specifier: "%.2f")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch event.kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .block: return "xmark.octagon.fill"
        case .override: return "arrow.uturn.right.circle.fill"
        case .pause: return "pause.circle.fill"
        case .resume: return "play.circle.fill"
        case .ruleCreated, .ruleUpdated, .ruleDeleted: return "doc.text.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .warning: return .orange
        case .block: return .red
        case .override: return .purple
        case .pause: return .gray
        case .resume: return .blue
        case .ruleCreated, .ruleUpdated, .ruleDeleted: return .secondary
        }
    }

    private var kindLabel: String {
        switch event.kind {
        case .warning: return "Warning fired"
        case .block: return "Request blocked"
        case .override: return "Override used"
        case .pause: return "Gate paused"
        case .resume: return "Gate resumed"
        case .ruleCreated: return "Rule created"
        case .ruleUpdated: return "Rule updated"
        case .ruleDeleted: return "Rule deleted"
        }
    }
}

// MARK: - Editor (push)

struct BudgetRuleEditorView: View {
    @Bindable var budgetSettings: BudgetSettings
    @State var rule: BudgetRule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            ruleFields
            saveSection
            deleteSection
        }
        .navigationTitle(rule.displayLabel)
        .navigationBarBackButtonHidden(false)
    }

    private var ruleFields: some View {
        Section {
            TextField("Label", text: Binding(get: { rule.label ?? "" }, set: { rule.label = $0.isEmpty ? nil : $0 }))
            HStack {
                Text("$")
                TextField("Amount", value: $rule.amountUSD, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
            }
            Picker("Period", selection: $rule.period) {
                Text("Day").tag(BudgetPeriod.day)
                Text("Week").tag(BudgetPeriod.week)
                Text("Month").tag(BudgetPeriod.month)
                Text("All time").tag(BudgetPeriod.allTime)
            }
            Picker("Behavior", selection: $rule.behavior) {
                Text("Warn then block").tag(BudgetBehavior.warnThenBlock)
                Text("Hard block").tag(BudgetBehavior.hardBlock)
                Text("Warn only").tag(BudgetBehavior.warnOnly)
                Text("Block + failover").tag(BudgetBehavior.hardBlockWithFallback)
            }
            Toggle("Enabled", isOn: $rule.isEnabled)
        } header: {
            Text("Rule")
        } footer: {
            if rule.scope == .credential {
                Text("Apply to a specific provider + account. Phase 4 wires the gate at the request layer; until then this rule simply tracks intent and shows projected hit dates.")
                    .font(.caption2)
            } else if rule.scope == .project {
                Text("Apply to a specific project name (matches the `projectName` column on every usage row).")
                    .font(.caption2)
            }
        }
    }

    private var saveSection: some View {
        Section {
            Button("Save changes") {
                budgetSettings.upsertRule(rule)
                dismiss()
            }
            .disabled(rule.amountUSD <= 0)
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Delete rule", role: .destructive) {
                budgetSettings.deleteRule(id: rule.id)
                dismiss()
            }
        }
    }
}

// MARK: - Editor (sheet for new rule)

struct BudgetRuleEditorSheet: View {
    @Bindable var budgetSettings: BudgetSettings
    @State var rule: BudgetRule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if rule.scope == .credential {
                        TextField("Provider (anthropic, openai, openrouter, …)", text: Binding(get: { rule.providerID ?? "" }, set: { rule.providerID = $0.isEmpty ? nil : $0 }))
                        TextField("Account / key label (optional)", text: Binding(get: { rule.accountID ?? "" }, set: { rule.accountID = $0.isEmpty ? nil : $0 }))
                    }
                    if rule.scope == .project {
                        TextField("Project name", text: Binding(get: { rule.projectName ?? "" }, set: { rule.projectName = $0.isEmpty ? nil : $0 }))
                    }
                    TextField("Display label (optional)", text: Binding(get: { rule.label ?? "" }, set: { rule.label = $0.isEmpty ? nil : $0 }))
                    HStack {
                        Text("Amount")
                        Spacer()
                        Text("$")
                        TextField("50", value: $rule.amountUSD, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    Picker("Period", selection: $rule.period) {
                        Text("Day").tag(BudgetPeriod.day)
                        Text("Week").tag(BudgetPeriod.week)
                        Text("Month").tag(BudgetPeriod.month)
                        Text("All time").tag(BudgetPeriod.allTime)
                    }
                    Picker("Behavior", selection: $rule.behavior) {
                        Text("Warn then block").tag(BudgetBehavior.warnThenBlock)
                        Text("Hard block").tag(BudgetBehavior.hardBlock)
                        Text("Warn only").tag(BudgetBehavior.warnOnly)
                        Text("Block + failover").tag(BudgetBehavior.hardBlockWithFallback)
                    }
                } header: {
                    Text("New \(rule.scope.rawValue) rule")
                }
            }
            .navigationTitle("New rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if rule.label?.isEmpty != false { rule.label = nil }
                        budgetSettings.upsertRule(rule)
                        dismiss()
                    }
                    .disabled(saveDisabled)
                }
            }
        }
    }

    private var saveDisabled: Bool {
        if rule.amountUSD <= 0 { return true }
        if rule.scope == .credential, (rule.providerID ?? "").isEmpty { return true }
        if rule.scope == .project, (rule.projectName ?? "").isEmpty { return true }
        return false
    }
}
