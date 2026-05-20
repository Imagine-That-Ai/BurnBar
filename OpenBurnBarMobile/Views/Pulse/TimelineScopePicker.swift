import SwiftUI
import OpenBurnBarCore

// MARK: - Pulse Timeline Scope
//
// Granularity for the Pulse home feed. Each case maps to the nearest
// available `RollupWindowKey` so the data layer doesn't need changes.
// When minute- / hour-level rollups land, the mapping narrows automatically.

enum PulseTimelineScope: String, CaseIterable, Identifiable {
    case minute, hour, day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minute: return "1M"
        case .hour:   return "1H"
        case .day:    return "1D"
        case .week:   return "7D"
        case .month:  return "30D"
        }
    }

    var headerLabel: String {
        switch self {
        case .minute: return "LIVE · MINUTE"
        case .hour:   return "LAST HOUR · LIVE"
        case .day:    return "LAST 24H · LIVE"
        case .week:   return "7 DAYS"
        case .month:  return "30 DAYS"
        }
    }

    /// Map to the closest available rollup window key.
    var rollupKey: RollupWindowKey {
        switch self {
        case .minute: return .today
        case .hour:   return .today
        case .day:    return .today
        case .week:   return .sevenDays
        case .month:  return .thirtyDays
        }
    }

    /// Trailing comparison window for delta calculations.
    var trailingKey: RollupWindowKey {
        switch self {
        case .minute: return .today
        case .hour:   return .today
        case .day:    return .sevenDays
        case .week:   return .thirtyDays
        case .month:  return .ninetyDays
        }
    }

    var icon: String {
        switch self {
        case .minute: return "bolt.fill"
        case .hour:   return "clock"
        case .day:    return "sun.max.fill"
        case .week:   return "calendar"
        case .month:  return "calendar.badge.clock"
        }
    }
}

// MARK: - Timeline Scope Picker

struct TimelineScopePicker: View {
    @Binding var selection: PulseTimelineScope

    @Namespace private var pickerNS

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PulseTimelineScope.allCases) { scope in
                Button {
                    HapticBus.chipChange()
                    withAnimation(AuroraDesign.Motion.auroraSnap) {
                        selection = scope
                    }
                } label: {
                    Text(scope.label)
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .tracking(0.4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(selection == scope ? .white : MobileTheme.Colors.textMuted)
                        .background {
                            if selection == scope {
                                Capsule()
                                    .fill(MobileTheme.primaryGradient)
                                    .matchedGeometryEffect(id: "scope", in: pickerNS)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(scope.label) timeline")
                .accessibilityAddTraits(selection == scope ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            Capsule().fill(MobileTheme.Colors.surface.opacity(0.55))
        )
        .overlay(
            Capsule().stroke(MobileTheme.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
        )
    }
}

// MARK: - Display Mode Toggle
//
// Currency / Tokens chip used by Pulse's top toolbar. Lives next to the
// timeline scope picker so the two read as a single control row across iOS
// and Android.

struct PulseDisplayModeToggle: View {
    @Binding var displayMode: UsageDisplayMode

    var body: some View {
        Button {
            withAnimation(AuroraDesign.Motion.auroraSnap) {
                displayMode = displayMode == .currency ? .tokens : .currency
            }
            HapticBus.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: displayMode == .currency ? "dollarsign" : "number")
                    .font(.system(size: 12, weight: .bold))
                Text(displayMode.label)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(MobileTheme.ember)
            .background(Capsule().fill(MobileTheme.ember.opacity(0.18)))
            .overlay(Capsule().stroke(MobileTheme.ember.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle currency or tokens")
    }
}
