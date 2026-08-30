import SwiftUI
import OpenBurnBarCore

/// Appearance → Menu Bar editor for the menu-bar popover body.
///
/// One layout model: which sections appear, their order, relative space,
/// min/max, collapse, and hide. This is the recovery surface for sections
/// hidden from the popover itself.
struct PopoverTrayLayoutSettingsPanel: View {
    @Bindable var settingsManager: SettingsManager

    private var layout: PopoverTrayLayout {
        settingsManager.popoverTrayLayout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menu bar popover")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Choose which blocks appear, their order, and how much of the tray each one occupies. Hidden sections leave no blank gap.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DesignSystem.Spacing.sm)
                Button("Restore default") {
                    var next = layout
                    next.restoreDefaults()
                    settingsManager.popoverTrayLayout = next
                }
                .buttonStyle(.link)
                .font(DesignSystem.Typography.tiny)
                .disabled(layout == .default())
            }

            VStack(spacing: 0) {
                ForEach(Array(layout.sections.enumerated()), id: \.element.id) { index, spec in
                    PopoverTrayLayoutSectionRow(
                        spec: spec,
                        index: index,
                        totalCount: layout.sections.count,
                        share: PopoverTrayLayoutMath.relativeShare(of: spec.id, in: layout),
                        onChange: { mutate in
                            var next = layout
                            mutate(&next)
                            settingsManager.popoverTrayLayout = next
                        }
                    )
                    if index < layout.sections.count - 1 {
                        Divider()
                            .background(DesignSystem.Colors.border.opacity(0.35))
                            .padding(.leading, 44)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
            )
        }
    }
}

private struct PopoverTrayLayoutSectionRow: View {
    let spec: PopoverTraySectionSpec
    let index: Int
    let totalCount: Int
    let share: Double
    let onChange: ((inout PopoverTrayLayout) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: spec.id.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.id.accessibilityLabel)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(spec.isHidden
                            ? DesignSystem.Colors.textMuted
                            : DesignSystem.Colors.textPrimary)
                    Text(statusLine)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 0)

                Button {
                    onChange { $0.move(spec.id, offset: -1) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .accessibilityLabel("Move \(spec.id.accessibilityLabel) up")

                Button {
                    onChange { $0.move(spec.id, offset: 1) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index >= totalCount - 1)
                .accessibilityLabel("Move \(spec.id.accessibilityLabel) down")

                Button {
                    onChange { $0.setCollapsed(spec.id, collapsed: !spec.isCollapsed) }
                } label: {
                    Image(systemName: spec.isCollapsed ? "rectangle.compress.vertical" : "rectangle.split.1x2")
                }
                .disabled(spec.isHidden)
                .accessibilityLabel(spec.isCollapsed
                    ? "Expand \(spec.id.accessibilityLabel)"
                    : "Collapse \(spec.id.accessibilityLabel)")

                Toggle("Show \(spec.id.accessibilityLabel)", isOn: Binding(
                    get: { !spec.isHidden },
                    set: { visible in onChange { $0.setHidden(spec.id, hidden: !visible) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Show \(spec.id.accessibilityLabel) in the popover")
            }

            if !spec.isHidden && !spec.isCollapsed {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text("Space")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 36, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { spec.effectiveWeight },
                            set: { newValue in
                                onChange { layout in
                                    layout.setWeight(spec.id, weight: newValue)
                                    if spec.pinnedHeight != nil {
                                        layout.setPinnedHeight(spec.id, height: nil)
                                    }
                                }
                            }
                        ),
                        in: PopoverTrayLayoutMath.minWeight...PopoverTrayLayoutMath.maxWeight
                    )
                    .accessibilityLabel("\(spec.id.accessibilityLabel) space")
                    Text(shareLabel)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.amber)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }

                HStack(spacing: DesignSystem.Spacing.md) {
                    Stepper(
                        "Min \(Int(spec.effectiveMinHeight.rounded())) pt",
                        value: Binding(
                            get: { spec.effectiveMinHeight },
                            set: { newValue in onChange { $0.setMinHeight(spec.id, minHeight: newValue) } }
                        ),
                        in: PopoverTrayLayoutMath.absoluteMinHeight...spec.effectiveMaxHeight,
                        step: 8
                    )
                    .font(DesignSystem.Typography.tiny)

                    Stepper(
                        "Max \(Int(spec.effectiveMaxHeight.rounded())) pt",
                        value: Binding(
                            get: { spec.effectiveMaxHeight },
                            set: { newValue in onChange { $0.setMaxHeight(spec.id, maxHeight: newValue) } }
                        ),
                        in: spec.effectiveMinHeight...PopoverTrayLayoutMath.absoluteMaxHeight,
                        step: 16
                    )
                    .font(DesignSystem.Typography.tiny)

                    if spec.pinnedHeight != nil {
                        Button("Clear fixed height") {
                            onChange { $0.setPinnedHeight(spec.id, height: nil) }
                        }
                        .buttonStyle(.link)
                        .font(DesignSystem.Typography.tiny)
                    }
                }
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .accessibilityIdentifier("settings.popoverLayout.\(spec.id.rawValue)")
    }

    private var statusLine: String {
        if spec.isHidden { return "Hidden — no gap in the tray" }
        if spec.isCollapsed { return "Collapsed to a labeled strip" }
        if spec.pinnedHeight != nil {
            return "Fixed height \(Int((spec.pinnedHeight ?? 0).rounded())) pt"
        }
        return spec.id.settingsSubtitle
    }

    private var shareLabel: String {
        "\(Int((share * 100).rounded()))%"
    }
}
