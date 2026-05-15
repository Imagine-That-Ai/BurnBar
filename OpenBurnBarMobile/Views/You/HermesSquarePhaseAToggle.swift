import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Square Phase A Toggle
//
// Settings → Experimental row. Lets the user opt in to the new Hermes
// Square super-app surface ahead of GA. When on, the `.hermes` tab routes
// to `HermesSquareRoot` instead of the legacy `AssistantsTabRoot`. Off by
// default; user choice persists via `HermesSquareFeatureFlags.phaseA`.

struct HermesSquarePhaseAToggle: View {
    @State private var flags = HermesSquareFeatureFlags.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { flags.phaseA },
            set: { flags.phaseA = $0 }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes Square (beta)")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(flags.phaseA
                         ? "Unified inbox · pinned grid · federated search"
                         : "Off — the runtime pill is the default Assistants surface.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(2)
                }
            } icon: {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MobileTheme.mercuryGradient)
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "151210"))
                }
            }
        }
    }
}
