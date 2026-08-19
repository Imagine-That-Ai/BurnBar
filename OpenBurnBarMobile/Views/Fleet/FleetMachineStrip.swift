import SwiftUI
import OpenBurnBarKernel

// MARK: - Fleet Machine Strip (iOS)
//
// Machine status card: CPU, memory, load, disk free in a compact two-column
// grid, plus the typed thermal/power sensors as full-width rows. Port of the
// Mac's `FleetMachinePanel` honesty rules (VAL-DASH-011/022/030): absent
// optional metrics render "—" with an accessible "unavailable" label, typed
// sensors render their value or their honest unavailability reason. Nothing
// is ever fabricated to look current.

struct FleetMachineStrip: View {
    let machine: BurnBarMachineStatus

    /// The compact numeric metrics; thermal/power stay full-width rows so
    /// their unavailability reasons have room to be read. Mirrors the Mac's
    /// `FleetViewModel.headerMachineMetricLabels`.
    private static let metricLabels = ["CPU", "Memory", "Load", "Disk free"]

    private var rows: [FleetMachineRow] {
        FleetMachineRow.rows(for: machine)
    }

    private var metricRows: [FleetMachineRow] {
        rows.filter { Self.metricLabels.contains($0.label) }
    }

    private var sensorRows: [FleetMachineRow] {
        rows.filter { !Self.metricLabels.contains($0.label) }
    }

    var body: some View {
        AuroraGlassCard(variant: .standard, padding: MobileTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .topLeading),
                        GridItem(.flexible(), alignment: .topLeading)
                    ],
                    spacing: MobileTheme.Spacing.md
                ) {
                    ForEach(metricRows) { row in
                        metricTile(row)
                    }
                }

                Divider()
                    .background(MobileTheme.Colors.borderSubtle.opacity(0.5))

                VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                    ForEach(sensorRows) { row in
                        sensorRow(row)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metricTile(_ row: FleetMachineRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Text(row.value ?? "—")
                .font(MobileTheme.Typography.monoSmall)
                .foregroundStyle(
                    row.isUnavailable
                        ? MobileTheme.Colors.textSecondary
                        : MobileTheme.Colors.textPrimary
                )
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private func sensorRow(_ row: FleetMachineRow) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Text(row.label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Spacer(minLength: MobileTheme.Spacing.sm)

            Text(row.value ?? "—")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(
                    row.isUnavailable
                        ? MobileTheme.Colors.textSecondary
                        : MobileTheme.Colors.textPrimary
                )
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
