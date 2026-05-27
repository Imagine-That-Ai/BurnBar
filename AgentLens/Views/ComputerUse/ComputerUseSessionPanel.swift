#if canImport(SwiftUI) && canImport(AppKit) && !DISTRIBUTION_MAS
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Settings → Computer Use panel. Trust-mode pill picker, scope-rule
/// list (with add/remove), latest audit-chain entries, panic-stop
/// button. Plan § D.1.
public struct ComputerUseSessionPanel: View {
    @ObservedObject var model: ComputerUseSessionPanelModel
    @State private var showingScopeEditor = false
    @State private var isPanicHovered = false

    public init(model: ComputerUseSessionPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            trustModePicker

            scopeRuleList

            recentAuditChain

            panicButton
                .padding(.top, 4)

            footer
        }
        .sheet(isPresented: $showingScopeEditor) {
            ComputerUseScopeRuleEditor(
                builtInDenies: model.scopeRules.filter { $0.effect == .deny && $0.origin == .builtIn },
                currentContext: model.currentScopePreviewContext
            ) { rule in
                model.addRule(rule)
                showingScopeEditor = false
            } onCancel: {
                showingScopeEditor = false
            }
        }
    }

    private var trustModePicker: some View {
        SettingsGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.amber)
                    Text("Session Trust Mode")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer(minLength: 12)
                    Text(model.liveTrustMode.rawValue.capitalized)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.amber.opacity(0.14))
                                .overlay(
                                    Capsule()
                                        .stroke(DesignSystem.Colors.amber.opacity(0.45), lineWidth: 0.75)
                                )
                        )
                        .foregroundStyle(DesignSystem.Colors.amber)
                }

                Text("Enforce action approval policies for the current session. Trusted mode allows the agent to drive Playwright or post CGEvents without per-step user signoff.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Picker("Trust mode", selection: trustModeBinding) {
                    ForEach(ComputerUseTrustMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
            }
        }
    }

    private var trustModeBinding: Binding<ComputerUseTrustMode> {
        Binding(
            get: { model.liveTrustMode },
            set: { newMode in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    model.setTrustMode(newMode)
                }
            }
        )
    }

    private var scopeRuleList: some View {
        SettingsGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.righthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.whimsy)
                    Text("Safety Boundary Rules")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer(minLength: 12)
                    Text("\(model.scopeRules.count) rules")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Text("Trusted mode will only execute without approval if the active browser URL, application bundle ID, or active window title matches one of these rules.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Divider().opacity(0.22)

                VStack(spacing: 0) {
                    ForEach(Array(model.scopeRules.enumerated()), id: \.element.id) { index, rule in
                        scopeRuleRow(rule)
                        if index < model.scopeRules.count - 1 {
                            Divider()
                                .opacity(0.14)
                                .padding(.leading, 22)
                        }
                    }
                }

                SettingsGlassButton(title: "Add Scope Rule", icon: "plus.circle") {
                    model.requestAddRule()
                    showingScopeEditor = true
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func scopeRuleRow(_ rule: ComputerUseScopeRule) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(rule.effect == .allow ? DesignSystem.Colors.success : DesignSystem.Colors.error)
                .frame(width: 8, height: 8)

            Text(rule.effect == .allow ? "allow" : "deny")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(
                    rule.effect == .allow
                        ? DesignSystem.Colors.success
                        : DesignSystem.Colors.error
                )
                .frame(width: 36, alignment: .leading)

            Text(rule.label)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(originLabel(for: rule.origin))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            if rule.origin == .user {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.removeRule(rule.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.error)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Remove custom rule")
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func originLabel(for origin: ComputerUseScopeRule.Origin) -> String {
        switch origin {
        case .builtIn: return "built-in"
        case .user: return "custom"
        case .imported: return "imported"
        }
    }

    private var recentAuditChain: some View {
        SettingsGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "list.number")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Text("Recent Cryptographic Audit Chain")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }

                Text("Real-time activity logs cryptographically sealed via hash linking.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Divider()
                    .opacity(0.3)

                VStack(alignment: .leading, spacing: 4) {
                    // Terminal Column Headers
                    HStack(spacing: 12) {
                        Text("IDX")
                            .frame(width: 26, alignment: .leading)
                        Text("STATE")
                            .frame(width: 44, alignment: .leading)
                        Text("ACTION DETAILS / FORENSIC SUMMARY")
                            .alignmentGuide(.leading) { d in d[.leading] }
                        Spacer()
                        Text("STATUS")
                            .frame(width: 78, alignment: .trailing)
                    }
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)

                    if model.recentAuditEntries.isEmpty {
                        Text("No entries recorded for this active session.")
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(model.recentAuditEntries.prefix(10), id: \.entryIndex) { entry in
                                HStack(spacing: 12) {
                                    Text(String(format: "%02d", entry.entryIndex))
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .frame(width: 26, alignment: .leading)

                                    Image(systemName: glyph(for: entry.status))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(color(for: entry.status))
                                        .frame(width: 44, alignment: .leading)

                                    Text(entry.summary)
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(entry.status.rawValue.uppercased())
                                        .font(DesignSystem.Typography.monoTiny)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(color(for: entry.status))
                                        .frame(width: 78, alignment: .trailing)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 8)
                                .background(
                                    entry.entryIndex % 2 == 0
                                        ? Color.black.opacity(0.12)
                                        : Color.black.opacity(0.06)
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                        )
                    }
                }
            }
        }
    }

    private var panicButton: some View {
        Button(role: .destructive) {
            model.panicHalt()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("PANIC STOP — HALT DAEMON ENGINE")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(0.5)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "FF3B30"), Color(hex: "C62828")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    if isPanicHovered {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.15))
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color(hex: "FF3B30").opacity(isPanicHovered ? 0.45 : 0.25),
                radius: isPanicHovered ? 12 : 6,
                x: 0,
                y: 3
            )
            .scaleEffect(isPanicHovered ? 1.015 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isPanicHovered)
        }
        .buttonStyle(.plain)
        .onHover { isPanicHovered = $0 }
    }

    private var footer: some View {
        HStack {
            Label(
                "Audit Root: " + (model.auditHeadHashHex?.prefix(10).description ?? "EMPTY"),
                systemImage: "lock.shield.fill"
            )
            .font(DesignSystem.Typography.monoTiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)

            Spacer()

            if let started = model.currentSessionStartedAt {
                Label(
                    "Session active since " + formatter.string(from: started),
                    systemImage: "clock.fill"
                )
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.horizontal, 4)
    }

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func glyph(for status: HermesRealtimeRelayActionLogEntry.Status) -> String {
        switch status {
        case .planned: return "circle"
        case .awaitingApproval: return "questionmark.circle.fill"
        case .executing: return "circle.dashed.inset.filled"
        case .completed: return "checkmark.circle.fill"
        case .failed, .rejected, .panicHalted: return "xmark.circle.fill"
        }
    }

    private func color(for status: HermesRealtimeRelayActionLogEntry.Status) -> Color {
        switch status {
        case .planned, .awaitingApproval: return DesignSystem.Colors.textMuted
        case .executing: return DesignSystem.Colors.amber
        case .completed: return DesignSystem.Colors.success
        case .failed, .rejected, .panicHalted: return DesignSystem.Colors.error
        }
    }
}

/// Observable model the panel reads from. Owned by
/// `ComputerUseSessionCoordinator`.
@MainActor
public final class ComputerUseSessionPanelModel: ObservableObject {
    @Published public var liveTrustMode: ComputerUseTrustMode = .manual
    @Published public var scopeRules: [ComputerUseScopeRule] = []
    @Published public var recentAuditEntries: [HermesRealtimeRelayActionLogEntry] = []
    @Published public var auditHeadHashHex: String?
    @Published public var currentSessionStartedAt: Date?
    @Published public var currentScopePreviewContext = ComputerUseScopeContext()

    public var setTrustMode: (ComputerUseTrustMode) -> Void = { _ in }
    public var removeRule: (ComputerUseScopeRuleID) -> Void = { _ in }
    public var requestAddRule: () -> Void = {}
    public var addRule: (ComputerUseScopeRule) -> Void = { _ in }
    public var panicHalt: () -> Void = {}

    public init() {}
}
#endif
