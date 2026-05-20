import AppKit
import SwiftUI
import WebKit
struct UsageModeToolbarPicker: View {
    @Binding var selection: UsageDisplayMode

    var body: some View {
        Menu {
            ForEach(UsageDisplayMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    HStack {
                        Text(mode.label)
                        if selection == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: leadingSymbol(for: selection))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(selection.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.leading, 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .toolbarPill()
        }
        .menuStyle(.borderlessButton)
        .help("Show totals in USD or token volume")
    }

    private func leadingSymbol(for mode: UsageDisplayMode) -> String {
        switch mode.label.lowercased() {
        case let l where l.contains("usd") || l.contains("$") || l.contains("cost"):
            return "dollarsign"
        default:
            return "number"
        }
    }
}

struct DashboardBackdrop: View {
    let moodBand: MoodBand

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.ember
                .opacity(0.035)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: 520)
                        .rotationEffect(.degrees(-11))
                        .offset(x: -260, y: -80)
                }

            DesignSystem.Colors.whimsy
                .opacity(0.025)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(alignment: .bottomTrailing) {
                    Rectangle()
                        .frame(width: 460)
                        .rotationEffect(.degrees(15))
                        .offset(x: 220, y: 110)
                }
        }
    }
}
