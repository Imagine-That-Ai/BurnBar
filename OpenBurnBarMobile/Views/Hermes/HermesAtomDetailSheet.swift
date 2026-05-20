import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Atom Detail Sheet
//
// Quick-look surface presented when the user taps an atom chip. Two design
// decisions:
//
//   1. Sheet, not push — tapping a chip should never destroy the in-flight
//      conversation. The user previews, optionally jumps in deeper, and
//      returns.
//   2. Single primary action — every atom has exactly one obvious next
//      step ("Open burn detail", "Switch to this model", etc.). The body
//      explains what the action does so users feel safe tapping.
//
// The actual destinations are owned by the host app's `HermesAtomRouter`;
// this sheet just displays + dispatches.

struct HermesAtomDetailSheet: View {
    let atom: HermesAtom
    let label: String
    let onOpen: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        masthead
                        actionSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle(atom.kind.categoryLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.34), .medium])
        .presentationDragIndicator(.visible)
    }

    private var masthead: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .frame(width: 48, height: 48)
                Image(systemName: atom.kind.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(2)
                Text(atom.kind.description)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Action".uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Button {
                HapticBus.primaryAction()
                onOpen()
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.right.square.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(actionLabel)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .opacity(0.55)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var actionLabel: String {
        switch atom {
        case .cost(_, let window):
            return "Open \(window.displayLabel) burn detail"
        case .session:
            return "Open session"
        case .provider(let token):
            return "Open \(token.capitalized) dashboard"
        case .model(let id):
            return "Use \(id)"
        case .window(let value):
            return "Switch to \(value.displayLabel)"
        case .tool(let name):
            return "Find \(name) in the run"
        case .project(let id):
            return "Open project \(id)"
        case .tokens:
            return "Open token detail"
        case .quota(let provider, _):
            return "Open \(provider.capitalized) quota"
        case .runtime(let profile):
            return "Open \(profile.capitalized) runtime"
        }
    }

    private var accent: Color {
        switch atom.kind {
        case .cost:     return MobileTheme.amber
        case .session:  return MobileTheme.hermesAureate
        case .provider: return MobileTheme.ember
        case .model:    return MobileTheme.whimsy
        case .window:   return MobileTheme.hermesAureate
        case .tool:     return MobileTheme.blaze
        case .project:  return MobileTheme.amber
        case .tokens:   return MobileTheme.success
        case .quota:    return MobileTheme.warning
        case .runtime:  return MobileTheme.hermesAureate
        }
    }
}

#Preview {
    HermesAtomDetailSheet(
        atom: .cost(amount: 2.34, window: .today),
        label: "$2.34 today",
        onOpen: {}
    )
}
