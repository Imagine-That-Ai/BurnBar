import SwiftUI
import OpenBurnBarCore

// MARK: - Quota Pulse Card
//
// Calm, scannable hero summary of fleet quota for the Pulse page.
//
// Replaces the overlapping `QuotaRingsConstellation` collage (which buried
// the fleet score under floating logos and was hard to parse at a glance)
// with a structured layout:
//
//   ┌─────────────────────────────────────┐
//   │ QUOTA              · Open ›         │   (header)
//   │                                     │
//   │   ╭───╮                             │
//   │   │76%│   76% remaining             │   (fleet hero)
//   │   ╰───╯   3 providers · all healthy │
//   │                                     │
//   │   ▌ Anthropic ━━━━━━━━━━━━━━━ 84%   │   (per-provider rows)
//   │   ▌ OpenAI    ━━━━━━━━━━━━━━━ 72%   │
//   │   ▌ Forge     ━━━━━━━━━━━━━━━ 28%   │
//   └─────────────────────────────────────┘

struct QuotaPulseCard: View {
    let snapshots: [ProviderQuotaSnapshot]
    let onSelect: (String) -> Void
    let onOpenBurn: () -> Void

    var body: some View {
        AuroraGlassCard(
            variant: hasUrgent ? .urgent : .standard,
            cornerRadius: AuroraDesign.Shape.heroCorner
        ) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                header

                if items.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "gauge.with.dots.needle.bottom.50percent",
                        title: "No quota signal yet",
                        message: "Connect a provider on your Mac to start tracking quota."
                    )
                    .frame(height: 180)
                } else {
                    fleetHero
                    Divider()
                        .background(MobileTheme.Colors.borderSubtle.opacity(0.5))
                    providerStack
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text("QUOTA")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer()
            Button(action: onOpenBurn) {
                HStack(spacing: 3) {
                    Text("Open")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.ember)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Burn page")
        }
    }

    // MARK: - Fleet Hero

    private var fleetHero: some View {
        let avg = fleetHealthRatio
        let pct = Int((avg * 100).rounded())
        return HStack(alignment: .center, spacing: MobileTheme.Spacing.lg) {
            FleetGauge(progress: avg, accent: statusColor)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(pct)% remaining")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .contentTransition(.numericText())
                Text(fleetSubtitle)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Provider Stack

    private var providerStack: some View {
        VStack(spacing: 6) {
            ForEach(items.prefix(5)) { item in
                Button {
                    HapticBus.sheetOpen()
                    onSelect(item.providerKey)
                } label: {
                    QuotaProviderRow(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.label), \(Int((item.pressureRemaining * 100).rounded())) percent remaining")
            }
            if items.count > 5 {
                Button(action: onOpenBurn) {
                    Text("\(items.count - 5) more · See all")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Derived

    private var fleetHealthRatio: Double {
        guard !items.isEmpty else { return 1.0 }
        return items.map(\.pressureRemaining).reduce(0, +) / Double(items.count)
    }

    private var statusColor: Color {
        if hasUrgent { return MobileTheme.warning }
        if fleetHealthRatio < 0.5 { return MobileTheme.amber }
        return MobileTheme.success
    }

    private var fleetSubtitle: String {
        let count = items.count
        let providerWord = count == 1 ? "provider" : "providers"
        if hasUrgent {
            let urgent = items.filter { $0.pressureRemaining < 0.25 }.count
            return "\(count) \(providerWord) · \(urgent) under pressure"
        }
        return "\(count) \(providerWord) · all healthy"
    }

    private var hasUrgent: Bool {
        snapshots.flatMap(\.buckets).contains { bucket in
            guard bucket.limit > 0 else { return false }
            return max(0, bucket.remaining) / bucket.limit < 0.25
        }
    }

    private var items: [QuotaRingsConstellation.Item] {
        let grouped = Dictionary(grouping: snapshots, by: { $0.providerID.rawValue })
        return grouped.compactMap { key, snaps -> QuotaRingsConstellation.Item? in
            guard let provider = AgentProvider.fromProviderID(ProviderID(rawValue: key))
                ?? AgentProvider.fromPersistedToken(key) else { return nil }
            let pressure = snaps
                .flatMap(\.buckets)
                .filter { $0.limit > 0 }
                .map { max(0, $0.remaining) / $0.limit }
                .min() ?? 1.0
            return QuotaRingsConstellation.Item(
                provider: provider,
                providerKey: key,
                pressureRemaining: pressure,
                label: provider.displayName
            )
        }
        // Most-pressured first; providerKey tiebreaker keeps row order stable
        // across Firestore updates.
        .sorted {
            if $0.pressureRemaining != $1.pressureRemaining {
                return $0.pressureRemaining < $1.pressureRemaining
            }
            return $0.providerKey < $1.providerKey
        }
    }
}

// MARK: - Fleet Gauge

/// Single readable progress ring for the fleet-level percent. Replaces the
/// previous floating-circles collage so the headline number reads instantly.
private struct FleetGauge: View {
    let progress: Double
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 7)

            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                .stroke(
                    AngularGradient(
                        colors: [
                            accent,
                            accent.opacity(0.85),
                            MobileTheme.amber,
                            accent
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: accent.opacity(0.4), radius: 8)
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress)

            Image(systemName: "flame.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Provider Row

/// Single per-provider row: tinted indicator, logo, name, progress bar,
/// percent. Reads top-to-bottom so the user can scan the fleet in one
/// sweep instead of decoding overlapping circles.
private struct QuotaProviderRow: View {
    let item: QuotaRingsConstellation.Item

    private var primary: Color {
        MobileTheme.Colors.primary(for: item.provider)
    }

    private var statusColor: Color {
        let p = item.pressureRemaining
        if p < 0.25 { return MobileTheme.error }
        if p < 0.5 { return MobileTheme.warning }
        return MobileTheme.success
    }

    private var pct: Int {
        Int((item.pressureRemaining * 100).rounded())
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            // Status indicator rail
            Capsule()
                .fill(statusColor)
                .frame(width: 3, height: 28)
                .accessibilityHidden(true)

            UnifiedProviderLogoView(provider: item.provider, size: 26, useFallbackColor: false)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.label)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                ProgressBar(value: item.pressureRemaining, tint: primary)
                    .frame(height: 5)
            }

            Spacer(minLength: 8)

            Text("\(pct)%")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(statusColor)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 38, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.6))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MobileTheme.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Provider Progress Bar

private struct ProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.16))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, geo.size.width * CGFloat(max(0, min(1, value)))))
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: value)
            }
        }
        .accessibilityHidden(true)
    }
}
