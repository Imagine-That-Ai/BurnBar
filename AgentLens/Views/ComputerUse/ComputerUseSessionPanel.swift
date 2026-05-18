#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Settings → Computer Use panel. Trust-mode pill picker, scope-rule
/// list (with add/remove), latest audit-chain entries, panic-stop
/// button. Plan § D.1.
///
/// The panel does NOT show an action queue — the active queue lives on
/// the phone (Decision 6).
public struct ComputerUseSessionPanel: View {
    @ObservedObject var model: ComputerUseSessionPanelModel
    @State private var showingScopeEditor = false

    public init(model: ComputerUseSessionPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            trustModePicker
            scopeRuleList
            recentAuditChain
            Spacer()
            panicButton
            footer
        }
        .padding(24)
        .frame(width: 720, height: 530)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("COMPUTER USE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.2)
            Text("Last 30 days")
                .font(.system(size: 24, weight: .semibold))
            Rectangle()
                .fill(LinearGradient(
                    colors: [.orange.opacity(0.6), .red.opacity(0.6)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(height: 1)
                .padding(.top, 4)
        }
    }

    private var trustModePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trust mode")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 0) {
                ForEach(ComputerUseTrustMode.allCases, id: \.self) { mode in
                    Button(action: { model.setTrustMode(mode) }) {
                        Text(mode.rawValue.capitalized)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(
                                mode == model.liveTrustMode
                                    ? AnyShapeStyle(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.secondary.opacity(0.1))
                            )
                            .foregroundStyle(mode == model.liveTrustMode ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(Capsule())
        }
    }

    private var scopeRuleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scope rules")
                .font(.system(size: 12, weight: .semibold))
            ForEach(model.scopeRules, id: \.id) { rule in
                HStack(spacing: 12) {
                    Image(systemName: rule.effect == .allow ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(rule.effect == .allow ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.label)
                            .font(.system(size: 12, design: .monospaced))
                        Text(rule.origin.rawValue)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if rule.origin == .user {
                        Button("Delete") { model.removeRule(rule.id) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    } else {
                        Text("built-in")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 5))
            }
            Button("+ Add scope rule") {
                model.requestAddRule()
                showingScopeEditor = true
            }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var recentAuditChain: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent audit chain")
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.recentAuditEntries.prefix(10), id: \.entryIndex) { entry in
                    HStack(spacing: 12) {
                        Text(String(format: "%02d", entry.entryIndex))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Image(systemName: glyph(for: entry.status))
                            .foregroundStyle(color(for: entry.status))
                        Text(entry.summary)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text(entry.status.rawValue)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var panicButton: some View {
        Button(role: .destructive) {
            model.panicHalt()
        } label: {
            Text("⛔  PANIC STOP")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    private var footer: some View {
        HStack {
            Text("Audit · " + (model.auditHeadHashHex?.prefix(10).description ?? "—"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            if let started = model.currentSessionStartedAt {
                Text("Session " + formatter.string(from: started))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func glyph(for status: HermesRealtimeRelayActionLogEntry.Status) -> String {
        switch status {
        case .planned: return "circle"
        case .awaitingApproval: return "questionmark.circle"
        case .executing: return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed, .rejected, .panicHalted: return "xmark.circle.fill"
        }
    }

    private func color(for status: HermesRealtimeRelayActionLogEntry.Status) -> Color {
        switch status {
        case .planned, .awaitingApproval: return .secondary
        case .executing: return .yellow
        case .completed: return .green
        case .failed, .rejected, .panicHalted: return .red
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
