import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Atom Chip (iOS)
//
// Atomic inline chip rendered for one `HermesAtom` inside the rich bubble.
// Visually compact: icon + label + faint accent fill. The chip's frame
// matches the `extraWidth` we pass to pretext, so wrap behavior stays in
// sync with the visual chrome.
//
// Tap action — defers to the `HermesAtomNavigator` provided via the
// environment, with a haptic confirmation.

struct HermesAtomChip: View {
    let atom: HermesAtom
    let label: String
    var size: ChipSize

    @Environment(\.hermesAtomNavigator) private var navigator

    enum ChipSize {
        case inline(baseSize: CGFloat)
        case standalone

        var fontSize: CGFloat {
            switch self {
            case .inline(let base): return max(11, base - 1)
            case .standalone: return 14
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .inline(let base): return max(9, base - 4)
            case .standalone: return 12
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .inline: return 7
            case .standalone: return 10
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .inline: return 1.5
            case .standalone: return 5
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .inline: return 7
            case .standalone: return 9
            }
        }
    }

    init(atom: HermesAtom, label: String, size: ChipSize = .standalone) {
        self.atom = atom
        self.label = label
        self.size = size
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 4) {
                Image(systemName: atom.kind.systemImage)
                    .font(.system(size: size.iconSize, weight: .bold))
                Text(label)
                    .font(.system(size: size.fontSize, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(accent.opacity(0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .stroke(accent.opacity(0.32), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(atom.kind.description)
        .accessibilityAddTraits(.isButton)
    }

    private func tap() {
        HapticBus.toggle()
        navigator.open(atom)
    }

    /// Per-atom-kind accent color, mapped to MobileTheme tokens. Kept here
    /// so chips look the same wherever they appear in iOS surfaces.
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

    private var accessibilityLabel: String {
        "\(atom.kind.categoryLabel): \(label)"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        HermesAtomChip(
            atom: .cost(amount: 2.34, window: .today),
            label: "$2.34 today"
        )
        HermesAtomChip(
            atom: .model(id: "claude-sonnet-4.7"),
            label: "Claude Sonnet 4.7"
        )
        HermesAtomChip(
            atom: .session(id: "abc-123"),
            label: "session abc-123"
        )
        HermesAtomChip(
            atom: .quota(provider: "anthropic", percent: 78),
            label: "78% Anthropic"
        )
    }
    .padding()
}
