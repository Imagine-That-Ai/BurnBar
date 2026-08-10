import SwiftUI

// MARK: - Control Switch
//
// The deck's on/off vocabulary, modelled on the shipped `ChartsPageView.aiToggle`.
//
// There is no `Toggle`, no `SwitchToggleStyle`, and no `Form` anywhere on the
// deck. Verified: zero occurrences of `SwitchToggleStyle` under
// `AgentLens/Views/Dashboard` and `AgentLens/Views/Charts` — the only
// `toggleStyle` calls there are `.checkbox`. A system switch paints a solid
// saturated accent fill, which is off the deck's opacity ladder entirely, and
// repeating one on fifteen glass plates would make the page read as a Settings
// pane wearing a glass coat.
//
// Glass cannot sample glass: this is the **one** nested real-glass control a
// tile may carry. Every secondary control uses `ControlSegmentedPicker` or
// `ControlLinkButton` below, which are non-glass by construction.

struct ControlSwitch: View {
    let kind: ControlKind
    let label: String
    let glyph: String
    let isOn: Bool
    /// Help text for each direction — the deck states the consequence, not the
    /// mechanism.
    let onHelp: String
    let offHelp: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : DesignSystem.Animation.standard) {
                action()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.bounce, value: isOn)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Circle()
                    .fill(isOn ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted.opacity(0.5))
                    .frame(width: 5, height: 5)
            }
            .foregroundStyle(isOn ? kind.accent : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlassInteractive(tint: isOn ? kind.accent.opacity(0.4) : nil, in: Capsule())
        .help(isOn ? onHelp : offHelp)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityIdentifier(OBBAccessibilityID.controlDeckToggle(kind.rawValue))
    }
}

// MARK: - Primary action

/// Replaces the switch in `.needsPermission` / `.unavailable`, where a switch
/// would be a lie: the OS or the subsystem owns the decision, so the deck can
/// only *ask*. The verb names exactly what will happen.
struct ControlPrimaryButton: View {
    let kind: ControlKind
    let title: String
    let glyph: String
    var tint: Color?
    let help: String
    let action: () -> Void

    private var resolvedTint: Color { tint ?? kind.accent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(resolvedTint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlassInteractive(tint: resolvedTint.opacity(0.4), in: Capsule())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .accessibilityIdentifier(OBBAccessibilityID.controlDeckToggle(kind.rawValue))
    }
}

// MARK: - Secondary controls (no nested glass)

/// The `SpendLensPicker` segmented form with the glass background replaced by a
/// flat accent capsule, because glass cannot sample glass and the tile already
/// spends its one glass control on the `ControlSwitch`.
struct ControlSegmentedPicker<Value: Hashable>: View {
    let accent: Color
    let options: [(value: Value, label: String)]
    let selection: Value
    let onSelect: (Value) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : DesignSystem.Animation.snappy) {
                        onSelect(option.value)
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(
                            selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                Capsule().fill(accent.opacity(colorScheme == .dark ? 0.16 : 0.10))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(accent.opacity(colorScheme == .dark ? 0.05 : 0.03)))
        .overlay(Capsule().stroke(accent.opacity(0.18), lineWidth: 0.75))
    }
}

/// A click-through into the surface that owns the heavy version of this
/// control. Flat, quiet, and always suffixed with the arrow, so a
/// click-through never wears the costume of a switch.
struct ControlLinkButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityHint(help)
    }
}
