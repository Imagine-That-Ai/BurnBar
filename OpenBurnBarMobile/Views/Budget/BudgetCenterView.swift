import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Budget Center View

/// A premium, beautiful dashboard for managing budget rules and viewing spending behavior.
/// First-class product surface in the Insights tab.
struct BudgetCenterView: View {
    @Bindable var budgetSettings: BudgetSettings
    let dashboardStore: DashboardStore

    @State private var spendByRule: [String: Double] = [:]
    @State private var forecasts: [String: BudgetForecast.Projection] = [:]
    @State private var recentEvents: [BudgetEvent] = []
    @State private var isLoading = true
    @State private var animateRing = false

    // Sheets & Editors
    @State private var showingAddRule = false
    @State private var selectedRuleScope: BudgetRuleScope = .global
    @State private var editingRule: BudgetRule?

    var body: some View {
        ZStack {
            if budgetSettings.rules.isEmpty {
                emptyStateView
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                ScrollView {
                    VStack(spacing: MobileTheme.Spacing.lg) {
                        // Hero Apple-Watch style ring
                        heroCard
                            .padding(.horizontal, AuroraDesign.Layout.cardInset)
                            .staggeredEntrance(delay: 0.05)

                        // Forecast Strip
                        forecastStrip
                            .staggeredEntrance(delay: 0.10)

                        // Rules List
                        rulesSection
                            .padding(.horizontal, AuroraDesign.Layout.cardInset)
                            .staggeredEntrance(delay: 0.15)

                        // Activity Feed
                        activitySection
                            .padding(.horizontal, AuroraDesign.Layout.cardInset)
                            .staggeredEntrance(delay: 0.20)
                    }
                    .padding(.top, MobileTheme.Spacing.sm)
                    .padding(.bottom, MobileTheme.Spacing.xxl * 2) // avoid tab overlap
                }
                .refreshable {
                    HapticBus.refreshStarted()
                    await loadData()
                    HapticBus.refreshFinished()
                }
            }

            if isLoading && budgetSettings.rules.isEmpty {
                ProgressView()
                    .tint(MobileTheme.ember)
                    .scaleEffect(1.2)
            }
        }
        .task {
            await loadData()
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                animateRing = true
            }
        }
        .onChange(of: budgetSettings.rules) { _, _ in
            Task { await loadData() }
        }
        .sheet(isPresented: $showingAddRule) {
            BudgetRuleEditorSheet(
                budgetSettings: budgetSettings,
                rule: BudgetRule(
                    scope: selectedRuleScope,
                    amountUSD: 50.0,
                    period: .month
                )
            )
        }
        .sheet(item: $editingRule) { rule in
            BudgetRuleEditorSheet(
                budgetSettings: budgetSettings,
                rule: rule
            )
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        let ledger = BudgetLedger(dataSource: dashboardStore)
        let forecastEngine = BudgetForecast(dataSource: dashboardStore)

        var newSpend: [String: Double] = [:]
        var newForecasts: [String: BudgetForecast.Projection] = [:]

        // Query spend and forecast for all rules
        for rule in budgetSettings.rules {
            let spend = await ledger.currentSpend(forRule: rule)
            newSpend[rule.id] = spend

            if rule.isEnabled {
                let proj = await forecastEngine.forecast(forRule: rule)
                newForecasts[rule.id] = proj
            }
        }

        let events = await budgetSettings.recentEvents(limit: 15)

        await MainActor.run {
            self.spendByRule = newSpend
            self.forecasts = newForecasts
            self.recentEvents = events
            self.isLoading = false
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            Spacer()

            // Icon with glowing aura
            ZStack {
                Circle()
                    .fill(MobileTheme.whimsy.opacity(0.12))
                    .frame(width: 100, height: 100)
                    .blur(radius: 8)

                Image(systemName: "wallet.pass.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(MobileTheme.whimsyGradient)
            }

            VStack(spacing: 8) {
                Text("Set your first budget")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(MobileTheme.textPrimary)

                Text("Define spending limits per day, week, or month. Get warnings before you hit the cap and hard blocks when you do.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                Button {
                    HapticBus.sheetOpen()
                    selectedRuleScope = .global
                    showingAddRule = true
                } label: {
                    Text("Add Global Limit")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule()
                                .fill(MobileTheme.primaryGradient)
                        )
                }

                Button {
                    HapticBus.sheetOpen()
                    selectedRuleScope = .credential
                    showingAddRule = true
                } label: {
                    Text("Limit Specific API Key")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MobileTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule()
                                .fill(MobileTheme.surface)
                                .stroke(MobileTheme.borderSubtle, lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 12)

            Spacer()
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
    }

    private var heroCard: some View {
        AuroraGlassCard(variant: .hero) {
            let stats = compositeStats
            VStack(spacing: MobileTheme.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BUDGET HEALTH")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .tracking(1.5)
                            .foregroundStyle(MobileTheme.textMuted)

                        Text(stats.healthStatus)
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundStyle(stats.statusColor)
                    }
                    Spacer()

                    // Top Scope / Behavior Indicator
                    HStack(spacing: 6) {
                        Image(systemName: stats.scopeIcon)
                            .font(.caption)
                        Text(stats.scopeLabel)
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.bold)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stats.statusColor.opacity(0.12))
                    .foregroundStyle(stats.statusColor)
                    .clipShape(Capsule())
                }

                // Apple-Watch style Ring & Center Info
                HStack(spacing: 24) {
                    ZStack {
                        // Track ring
                        Circle()
                            .stroke(MobileTheme.borderSubtle.opacity(0.4), lineWidth: 14)
                            .frame(width: 120, height: 120)

                        // Progress ring
                        Circle()
                            .trim(from: 0.0, to: animateRing ? CGFloat(min(stats.usedPercent, 1.0)) : 0.0)
                            .stroke(
                                stats.ringGradient,
                                style: StrokeStyle(lineWidth: 14, lineCap: .round)
                            )
                            .frame(width: 120, height: 120)
                            .rotationEffect(.degrees(-90))

                        // Pulse glow for over budget
                        if stats.usedPercent >= 1.0 {
                            Circle()
                                .stroke(MobileTheme.error.opacity(0.3), lineWidth: 18)
                                .frame(width: 120, height: 120)
                                .scaleEffect(animateRing ? 1.08 : 1.0)
                                .animation(
                                    .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                    value: animateRing
                                )
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("$\(String(format: "%.2f", stats.usedAmount))")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(MobileTheme.textPrimary)
                            Text(" usd")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.textMuted)
                        }

                        Text("of $\(String(format: "%.2f", stats.limitAmount)) \(stats.periodLabel)")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.textSecondary)

                        let percentInt = Int((stats.usedPercent * 100).rounded())
                        Text("\(percentInt)% utilized")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(stats.statusColor)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var forecastStrip: some View {
        let activeForecasts = forecasts.values.filter { $0.willExceed || ($0.projectedHitDate() != nil) }
        return Group {
            if !activeForecasts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PROJECTIONS & FORECASTS")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .tracking(1.5)
                        .foregroundStyle(MobileTheme.textMuted)
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: MobileTheme.Spacing.sm) {
                            ForEach(activeForecasts, id: \.ruleID) { proj in
                                if let rule = budgetSettings.rules.first(where: { $0.id == proj.ruleID }) {
                                    forecastChip(for: rule, projection: proj)
                                }
                            }
                        }
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func forecastChip(for rule: BudgetRule, projection: BudgetForecast.Projection) -> some View {
        let hitDate = projection.projectedHitDate()
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.displayLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MobileTheme.textPrimary)
                    .lineLimit(1)

                if projection.usedPercent >= 1.0 {
                    Text("Limit Breached")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MobileTheme.error)
                } else if let date = hitDate {
                    Text("ETA: \(date.formatted(.dateTime.day().month()))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MobileTheme.warning)
                } else {
                    Text("On Track")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MobileTheme.success)
                }
            }

            // Small bar
            VStack(alignment: .trailing, spacing: 3) {
                Text("$\(String(format: "%.1f", projection.currentSpend))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MobileTheme.textPrimary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(MobileTheme.borderSubtle.opacity(0.4))
                        Capsule()
                            .fill(projection.usedPercent >= 1.0 ? MobileTheme.error : (projection.usedPercent >= 0.8 ? MobileTheme.warning : MobileTheme.success))
                            .frame(width: geo.size.width * CGFloat(min(projection.usedPercent, 1.0)))
                    }
                }
                .frame(width: 44, height: 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                        .stroke(MobileTheme.borderSubtle.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    private var rulesSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("BUDGET RULES")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.5)
                    .foregroundStyle(MobileTheme.textMuted)

                Spacer()

                Menu {
                    Button {
                        HapticBus.sheetOpen()
                        selectedRuleScope = .global
                        showingAddRule = true
                    } label: {
                        Label("Global Rule", systemImage: "globe")
                    }

                    Button {
                        HapticBus.sheetOpen()
                        selectedRuleScope = .credential
                        showingAddRule = true
                    } label: {
                        Label("Credential Rule", systemImage: "key.fill")
                    }

                    Button {
                        HapticBus.sheetOpen()
                        selectedRuleScope = .project
                        showingAddRule = true
                    } label: {
                        Label("Project Rule", systemImage: "folder.fill")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MobileTheme.primaryGradient)
                }
            }
            .padding(.bottom, 4)

            ForEach(budgetSettings.rules) { rule in
                BudgetRuleCard(
                    rule: rule,
                    spend: spendByRule[rule.id] ?? 0.0,
                    projection: forecasts[rule.id],
                    onEdit: {
                        HapticBus.sheetOpen()
                        editingRule = rule
                    },
                    onPause: {
                        Task {
                            let oneHourLater = Date().addingTimeInterval(3600)
                            await budgetSettings.pauseRule(id: rule.id, until: oneHourLater)
                        }
                    },
                    onResume: {
                        Task {
                            await budgetSettings.resumeRule(id: rule.id)
                        }
                    },
                    onDelete: {
                        Task {
                            HapticBus.destructive()
                            await budgetSettings.deleteRule(id: rule.id)
                        }
                    }
                )
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT ACTIVITY")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.5)
                .foregroundStyle(MobileTheme.textMuted)
                .padding(.bottom, 4)

            if recentEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 24))
                        .foregroundStyle(MobileTheme.textMuted)
                    Text("No audit events recorded yet.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md)
                        .fill(MobileTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.md)
                                .stroke(MobileTheme.borderSubtle.opacity(0.3), lineWidth: 0.5)
                        )
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentEvents.enumerated()), id: \.1.id) { index, event in
                        BudgetEventTimelineRow(
                            event: event,
                            isLast: index == recentEvents.count - 1,
                            ruleLabel: budgetSettings.rules.first(where: { $0.id == event.ruleID })?.displayLabel ?? "Rule"
                        )
                    }
                }
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(MobileTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                .stroke(MobileTheme.borderSubtle.opacity(0.35), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    // MARK: - Composite Hero Calculations

    private struct HeroStats {
        let usedAmount: Double
        let limitAmount: Double
        let usedPercent: Double
        let healthStatus: String
        let statusColor: Color
        let ringGradient: LinearGradient
        let scopeLabel: String
        let scopeIcon: String
        let periodLabel: String
    }

    private var compositeStats: HeroStats {
        // If there's an enabled global rule, it anchors our dashboard hero
        if let globalRule = budgetSettings.globalRules.first(where: { $0.isEnabled }) {
            let used = spendByRule[globalRule.id] ?? 0.0
            let limit = globalRule.amountUSD
            let pct = limit > 0 ? used / limit : 0.0
            return buildStats(used: used, limit: limit, pct: pct, label: "Global Scope", icon: "globe", period: globalRule.period)
        }

        // If no global rule, find the most active rule (by usage percent)
        let activeRules = budgetSettings.rules.filter { $0.isEnabled && $0.amountUSD > 0 }
        if let worstRule = activeRules.max(by: { a, b in
            let pctA = (spendByRule[a.id] ?? 0.0) / a.amountUSD
            let pctB = (spendByRule[b.id] ?? 0.0) / b.amountUSD
            return pctA < pctB
        }) {
            let used = spendByRule[worstRule.id] ?? 0.0
            let limit = worstRule.amountUSD
            let pct = limit > 0 ? used / limit : 0.0
            let scopeLabel: String
            let icon: String
            switch worstRule.scope {
            case .credential:
                scopeLabel = worstRule.providerID ?? "Credential"
                icon = "key.fill"
            case .project:
                scopeLabel = worstRule.projectName ?? "Project"
                icon = "folder.fill"
            case .organization:
                scopeLabel = "Organization"
                icon = "building.2.fill"
            case .global:
                scopeLabel = "Global"
                icon = "globe"
            }
            return buildStats(used: used, limit: limit, pct: pct, label: scopeLabel, icon: icon, period: worstRule.period)
        }

        // Fallback placeholder when rules exist but are disabled or zero
        return buildStats(used: 0.0, limit: 1.0, pct: 0.0, label: "Empty", icon: "gauge", period: .month)
    }

    private func buildStats(used: Double, limit: Double, pct: Double, label: String, icon: String, period: BudgetPeriod) -> HeroStats {
        let color: Color
        let gradient: LinearGradient

        if pct >= 1.0 {
            color = MobileTheme.error
            gradient = LinearGradient(colors: [MobileTheme.error, MobileTheme.ember], startPoint: .top, endPoint: .bottom)
        } else if pct >= 0.8 {
            color = MobileTheme.warning
            gradient = LinearGradient(colors: [MobileTheme.warning, MobileTheme.amber], startPoint: .top, endPoint: .bottom)
        } else if pct >= 0.5 {
            color = MobileTheme.amber
            gradient = LinearGradient(colors: [MobileTheme.amber, .orange], startPoint: .top, endPoint: .bottom)
        } else {
            color = MobileTheme.success
            gradient = LinearGradient(colors: [MobileTheme.success, .emerald], startPoint: .top, endPoint: .bottom)
        }

        let statusText: String
        if pct >= 1.0 {
            statusText = "LIMIT EXCEEDED"
        } else if pct >= 0.8 {
            statusText = "CRITICAL BUFFER"
        } else if pct >= 0.5 {
            statusText = "STEADY CONSUMPTION"
        } else {
            statusText = "HEALTHY STANDBY"
        }

        let periodLabel: String
        switch period {
        case .day: periodLabel = "today"
        case .week: periodLabel = "this week"
        case .month: periodLabel = "this month"
        case .allTime: periodLabel = "all time"
        }

        return HeroStats(
            usedAmount: used,
            limitAmount: limit,
            usedPercent: pct,
            healthStatus: statusText,
            statusColor: color,
            ringGradient: gradient,
            scopeLabel: label,
            scopeIcon: icon,
            periodLabel: periodLabel
        )
    }
}

// MARK: - Premium Budget Rule Card

struct BudgetRuleCard: View {
    let rule: BudgetRule
    let spend: Double
    let projection: BudgetForecast.Projection?

    let onEdit: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0.0

    var body: some View {
        let pct = rule.amountUSD > 0 ? spend / rule.amountUSD : 0.0
        let isPaused = rule.isPaused()

        Button {
            onEdit()
        } label: {
            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    // Left Scope Icon & Details
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(scopeColor.opacity(0.12))
                                .frame(width: 38, height: 38)

                            Image(systemName: scopeIcon)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(scopeColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.displayLabel)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(isPaused ? MobileTheme.textMuted : MobileTheme.textPrimary)
                                .lineLimit(1)

                            HStack(spacing: 5) {
                                Text(behaviorLabel)
                                if isPaused {
                                    Text("·")
                                    Text("paused")
                                        .foregroundStyle(MobileTheme.amber)
                                }
                                if !rule.isEnabled {
                                    Text("·")
                                    Text("disabled")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(MobileTheme.textSecondary)
                        }
                    }

                    Spacer()

                    // Right Limit & Period
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$\(String(format: "%.2f", rule.amountUSD))")
                            .font(.system(.subheadline, design: .monospaced).weight(.bold))
                            .foregroundStyle(isPaused ? MobileTheme.textMuted : MobileTheme.textPrimary)

                        Text(periodLabel)
                            .font(.system(size: 10).weight(.medium))
                            .foregroundStyle(MobileTheme.textSecondary)
                    }
                }

                // Bar progress section
                VStack(spacing: 4) {
                    HStack {
                        Text("$\(String(format: "%.2f", spend)) spent")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(MobileTheme.textSecondary)

                        Spacer()

                        let percentInt = Int((pct * 100).rounded())
                        Text("\(percentInt)%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(isPaused ? MobileTheme.textMuted : progressColor(pct))
                    }

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(MobileTheme.borderSubtle.opacity(0.4))
                            Capsule()
                                .fill(isPaused ? MobileTheme.textMuted.opacity(0.5) : progressColor(pct))
                                .frame(width: geo.size.width * CGFloat(min(pct, 1.0)))
                        }
                    }
                    .frame(height: 5)
                }

                // Forecast projection indicator
                if let hitDate = projection?.projectedHitDate(), pct < 1.0 && !isPaused {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 9))
                        Text("Projected to breach: \(hitDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(MobileTheme.warning)
                    .padding(.top, 2)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(isPaused ? MobileTheme.borderSubtle.opacity(0.3) : MobileTheme.borderSubtle.opacity(0.45), lineWidth: 1)
                )
        )
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit Rule", systemImage: "pencil")
            }

            if isPaused {
                Button {
                    onResume()
                } label: {
                    Label("Resume Rule", systemImage: "play.fill")
                }
            } else {
                Button {
                    onPause()
                } label: {
                    Label("Pause 1hr", systemImage: "pause.fill")
                }
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Rule", systemImage: "trash")
            }
        }
    }

    // MARK: - Styling Helpers

    private var scopeIcon: String {
        switch rule.scope {
        case .global: return "globe"
        case .credential: return "key.fill"
        case .project: return "folder.fill"
        case .organization: return "building.2.fill"
        }
    }

    private var scopeColor: Color {
        switch rule.scope {
        case .global: return MobileTheme.whimsy
        case .credential: return MobileTheme.amber
        case .project: return MobileTheme.success
        case .organization: return MobileTheme.ember
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

    private var behaviorLabel: String {
        switch rule.behavior {
        case .warnThenBlock: return "warn & block"
        case .hardBlock: return "hard block"
        case .warnOnly: return "warn only"
        case .hardBlockWithFallback: return "block + failover"
        }
    }

    private func progressColor(_ pct: Double) -> Color {
        if pct >= 1.0 { return MobileTheme.error }
        if pct >= 0.8 { return MobileTheme.warning }
        if pct >= 0.5 { return MobileTheme.amber }
        return MobileTheme.success
    }
}

// MARK: - Budget Event Timeline Row

struct BudgetEventTimelineRow: View {
    let event: BudgetEvent
    let isLast: Bool
    let ruleLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Timeline line & node
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.15))
                        .frame(width: 28, height: 28)

                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }

                if !isLast {
                    Rectangle()
                        .fill(MobileTheme.borderSubtle.opacity(0.4))
                        .frame(width: 1.5)
                        .frame(minHeight: 24)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(eventDescription)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MobileTheme.textPrimary)

                HStack(spacing: 6) {
                    Text(ruleLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MobileTheme.textMuted)

                    Text("·")
                        .foregroundStyle(MobileTheme.textMuted)

                    Text(event.occurredAt.formatted(.dateTime.hour().minute().second()))
                        .font(.system(size: 10))
                        .foregroundStyle(MobileTheme.textSecondary)
                }
            }

            Spacer()

            if event.limitAtEvent > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("$\(String(format: "%.2f", event.amountAtEvent))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(MobileTheme.textPrimary)
                    Text("of $\(String(format: "%.0f", event.limitAtEvent))")
                        .font(.system(size: 9))
                        .foregroundStyle(MobileTheme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var iconName: String {
        switch event.kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .block: return "xmark.octagon.fill"
        case .override: return "arrow.uturn.right.circle.fill"
        case .pause: return "pause.fill"
        case .resume: return "play.fill"
        case .ruleCreated: return "plus"
        case .ruleUpdated: return "pencil"
        case .ruleDeleted: return "trash.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .warning: return MobileTheme.warning
        case .block: return MobileTheme.error
        case .override: return MobileTheme.whimsy
        case .pause: return MobileTheme.amber
        case .resume: return MobileTheme.success
        case .ruleCreated: return MobileTheme.success
        case .ruleUpdated: return MobileTheme.hermesMercury
        case .ruleDeleted: return MobileTheme.error
        }
    }

    private var eventDescription: String {
        switch event.kind {
        case .warning: return "Warning Threshold Reached"
        case .block: return "Relay Request Hard Blocked"
        case .override: return "Temporary Bypass Applied"
        case .pause: return "Budget Enforcement Paused"
        case .resume: return "Budget Enforcement Resumed"
        case .ruleCreated: return "New Budget Rule Synced"
        case .ruleUpdated: return "Budget Rule Updated"
        case .ruleDeleted: return "Budget Rule Deleted"
        }
    }
}

// MARK: - Premium Budget Rule Editor Sheet

struct BudgetRuleEditorSheet: View {
    @Bindable var budgetSettings: BudgetSettings
    @State private var rule: BudgetRule

    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool

    init(budgetSettings: BudgetSettings, rule: BudgetRule) {
        self.budgetSettings = budgetSettings
        self._rule = State(initialValue: rule)
        self.isNew = !budgetSettings.rules.contains(where: { $0.id == rule.id })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label (e.g. Sonnet Monthly Limit)", text: Binding(
                        get: { rule.label ?? "" },
                        set: { rule.label = $0.isEmpty ? nil : $0 }
                    ))
                    .autocorrectionDisabled()

                    HStack {
                        Text("Amount")
                            .foregroundStyle(MobileTheme.textPrimary)
                        Spacer()
                        Text("$")
                            .foregroundStyle(MobileTheme.textSecondary)
                        TextField("50.00", value: $rule.amountUSD, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(width: 100)
                    }

                    Picker("Reset Cadence", selection: $rule.period) {
                        Text("Daily").tag(BudgetPeriod.day)
                        Text("Weekly").tag(BudgetPeriod.week)
                        Text("Monthly").tag(BudgetPeriod.month)
                        Text("All Time").tag(BudgetPeriod.allTime)
                    }

                    Picker("Enforcement Behavior", selection: $rule.behavior) {
                        Text("Warn at 80%, Block at 100%").tag(BudgetBehavior.warnThenBlock)
                        Text("Hard Block at 100%").tag(BudgetBehavior.hardBlock)
                        Text("Warn only (Observability)").tag(BudgetBehavior.warnOnly)
                        Text("Block & Failover to fallback").tag(BudgetBehavior.hardBlockWithFallback)
                    }
                } header: {
                    Text("Basic Parameters")
                }

                if rule.scope == .credential {
                    Section {
                        TextField("Provider ID (e.g. anthropic, openai)", text: Binding(
                            get: { rule.providerID ?? "" },
                            set: { rule.providerID = $0.isEmpty ? nil : $0 }
                        ))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                        TextField("Account ID / Key Hashed Slot (optional)", text: Binding(
                            get: { rule.accountID ?? "" },
                            set: { rule.accountID = $0.isEmpty ? nil : $0 }
                        ))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    } header: {
                        Text("API Key Targeting")
                    } footer: {
                        Text("Enter 'anthropic' or 'openai' as the provider. Leave Account ID blank to apply to all accounts under that provider.")
                            .font(.caption2)
                            .foregroundStyle(MobileTheme.textSecondary)
                    }
                }

                if rule.scope == .project {
                    Section {
                        TextField("Project Name (exact match)", text: Binding(
                            get: { rule.projectName ?? "" },
                            set: { rule.projectName = $0.isEmpty ? nil : $0 }
                        ))
                        .autocorrectionDisabled()
                    } header: {
                        Text("Project Targeting")
                    } footer: {
                        Text("Matches the project labels configured in the streams/projects tab.")
                            .font(.caption2)
                            .foregroundStyle(MobileTheme.textSecondary)
                    }
                }

                Section {
                    Toggle("Enforce Rule", isOn: $rule.isEnabled)
                        .tint(MobileTheme.ember)
                } header: {
                    Text("State")
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await budgetSettings.deleteRule(id: rule.id)
                                dismiss()
                            }
                        } label: {
                            Text("Delete Rule")
                                .frame(maxWidth: .infinity)
                                .font(.subheadline.weight(.bold))
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Budget Rule" : "Edit Budget Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await budgetSettings.upsertRule(rule)
                            dismiss()
                        }
                    }
                    .disabled(saveDisabled)
                }
            }
        }
    }

    private var saveDisabled: Bool {
        if rule.amountUSD <= 0 { return true }
        if rule.scope == .credential && (rule.providerID ?? "").isEmpty { return true }
        if rule.scope == .project && (rule.projectName ?? "").isEmpty { return true }
        return false
    }
}

// MARK: - Extension to Color for emerald

extension Color {
    static let emerald = Color(red: 16/255, green: 185/255, blue: 129/255)
}
