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
        case .day:    return "TODAY · LIVE"
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
