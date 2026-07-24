import SwiftUI

// MARK: - Charts Customize Sheet
//
// The gallery's control room: palette mood, density, grid width, primary
// metric, and per-chart visibility / span / accent voice — all applied live
// against the page behind the sheet. Persistence happens in the page (it
// owns the storage keys); the sheet only mutates the two bindings.

struct ChartsCustomizeSheet: View {
    @Binding var layout: ChartsPageLayout
    @Binding var appearance: ChartsAppearance

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DesignSystem.Colors.borderSubtle)
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    lookSection
                    metricSection
                    chartsSection
                    resetSection
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .frame(width: 600, height: 680)
        .background(DesignSystem.Colors.background)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Customize the Gallery")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Changes apply instantly and persist across launches.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .liquidGlassInteractive(in: Circle())
            .accessibilityLabel("Close")
        }
        .padding(DesignSystem.Spacing.lg)
    }

    // MARK: Look (mood · density · columns)

    private var lookSection: some View {
        section(title: "Palette Mood") {
            VStack(spacing: DesignSystem.Spacing.sm) {
                moodPicker
                HStack(spacing: DesignSystem.Spacing.md) {
                    densityPicker
                    columnsPicker
                }
            }
        }
    }

    private var moodPicker: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(ChartsPaletteMood.allCases) { mood in
                let selected = appearance.paletteMood == mood
                Button {
                    appearance.paletteMood = mood
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: mood.swatch,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().stroke(
                                    selected ? DesignSystem.Colors.textPrimary : Color.clear,
                                    lineWidth: 2
                                )
                            )
                            .padding(2)
                        Text(mood.displayName)
                            .font(.system(size: 10, weight: selected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(
                                selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.5 : 0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(
                                selected
                                    ? appearance.paletteMood.color(for: .burn).opacity(0.6)
                                    : DesignSystem.Colors.borderSubtle,
                                lineWidth: selected ? 1.5 : 0.75
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mood.tagline)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var densityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Density")
            segmentedControl(
                options: ChartsDensity.allCases,
                title: { $0.displayName },
                isSelected: { appearance.density == $0 },
                select: { appearance.density = $0 }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnsPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Columns")
            segmentedControl(
                options: Array(ChartsAppearance.columnRange),
                title: { "\($0)" },
                isSelected: { appearance.columns == $0 },
                select: { appearance.setColumns($0) }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Metric

    private var metricSection: some View {
        section(title: "Primary Metric") {
            VStack(alignment: .leading, spacing: 6) {
                segmentedControl(
                    options: ChartsPrimaryMetric.allCases,
                    title: { $0.displayName },
                    isSelected: { appearance.primaryMetric == $0 },
                    select: { appearance.primaryMetric = $0 }
                )
                Text("Drives the hero counter, Burn Over Time, Burn Forecast, and Week vs Week.")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    // MARK: Charts list

    private var chartsSection: some View {
        section(title: "Charts") {
            VStack(spacing: 2) {
                ForEach(layout.configs) { config in
                    chartRow(config)
                    if config.id != layout.configs.last?.id {
                        Divider().overlay(DesignSystem.Colors.borderSubtle.opacity(0.6))
                    }
                }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.5 : 0.7))
            )
        }
    }

    private func chartRow(_ config: ChartCardConfig) -> some View {
        let kind = config.kind
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { config.isVisible },
                set: { layout.setVisible(kind, $0) }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(appearance.accent(for: kind))
                        .frame(width: 18)
                    Text(kind.title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 8)

            accentSwatches(kind)

            Stepper(value: Binding(
                get: { config.span },
                set: { layout.setSpan(kind, $0) }
            ), in: 1...appearance.columns) {
                Text("\(config.span == appearance.columns ? "Full" : "\(config.span)/\(appearance.columns)")")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 38, alignment: .trailing)
            }
            .frame(width: 130)
            .help("Card width in grid columns")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// The six accent voices in the active mood; the chart's default voice
    /// clears any override (per `setAccentSlot`).
    private func accentSwatches(_ kind: ChartKind) -> some View {
        HStack(spacing: 4) {
            ForEach(ChartsAccentSlot.allCases) { slot in
                let selected = appearance.slot(for: kind) == slot
                Button {
                    appearance.setAccentSlot(slot, for: kind)
                } label: {
                    Circle()
                        .fill(appearance.paletteMood.color(for: slot))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle().stroke(
                                selected ? DesignSystem.Colors.textPrimary : Color.clear,
                                lineWidth: 1.5
                            )
                        )
                        .padding(1)
                }
                .buttonStyle(.plain)
                .help("\(slot.displayName)\(slot == kind.defaultAccentSlot ? " (default)" : "")")
            }
        }
        .accessibilityLabel("Accent for \(kind.title)")
    }

    // MARK: Reset

    private var resetSection: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                layout.reset()
                appearance.reset()
            } label: {
                Text("Reset Everything")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignSystem.Colors.error)
            .help("Restore the default layout, mood, density, columns, and metric")
        }
    }

    // MARK: Shared chrome

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            content()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    private func segmentedControl<Option: Hashable>(
        options: [Option],
        title: @escaping (Option) -> String,
        isSelected: @escaping (Option) -> Bool,
        select: @escaping (Option) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = isSelected(option)
                Button {
                    select(option)
                } label: {
                    Text(title(option))
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                Capsule().fill(appearance.paletteMood.color(for: .burn).opacity(0.2))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.5 : 0.7))
        )
    }
}
