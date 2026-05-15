import SwiftUI
import OpenBurnBarCore

// MARK: - Mission FAB Resurrect Toggle
//
// Settings → Experimental row that exposes the third (most discoverable)
// resurrect path. Mirrors `HermesSquarePhaseAToggle` so the section reads
// as a consistent row of beta surfaces.
//
// When the orb is currently visible, the row is also a quick "Hide the
// orb" affordance — same control, both directions. The subtitle reflects
// the live state so the user knows what the toggle will do.

struct MissionFABResurrectToggle: View {
    @State private var resurrection = MissionFABResurrectionController.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { !resurrection.isDismissed },
            set: { newValue in
                if newValue {
                    resurrection.restoreFromSettings()
                } else {
                    resurrection.dismiss()
                }
            }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mission Console orb")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(2)
                }
            } icon: {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MobileTheme.mercuryGradient)
                        .frame(width: 26, height: 26)
                    Image(systemName: resurrection.isDismissed
                                      ? "circle.dotted"
                                      : "circle.hexagongrid.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "151210"))
                }
            }
        }
    }

    private var subtitle: String {
        if resurrection.isDismissed {
            if let when = resurrection.dismissedAt {
                let delta = Date().timeIntervalSince(when)
                let label = MissionConsoleFormatting.relativeTime(when, reference: Date())
                _ = delta
                return "Hidden \(label). Toggle on to bring it back — or flick from the edge dot."
            }
            return "Hidden. Toggle on to bring it back — or flick from the edge dot."
        }
        return "On. Drag to move, flick to dismiss, long-press for tooltip."
    }
}
