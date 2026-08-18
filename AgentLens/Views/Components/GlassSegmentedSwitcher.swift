import SwiftUI

// MARK: - Glass segmented switcher
//
// A compact mode picker: one chip that opens a menu.
//
// This is the collapsed branch of `DashboardLayoutSwitcher`, generalized over
// any option type. The *expanded* segmented form that switcher can show is
// deliberately not reproduced here: the Home rail is 280–460pt wide and a
// segmented control with four labelled options overflows on first render. A
// control that overflows the moment it appears is worse than a menu.

struct GlassSegmentedSwitcher<Option: HomeSwitcherOption>: View where Option.AllCases == [Option] {
    @Binding var selection: Option
    /// Options to offer. Defaults to every case, but callers gate this — the
    /// fleet panel hides `.timeline` until watchers are armed rather than
    /// shipping it present-and-empty.
    var options: [Option]
    /// Hide the label text, leaving only the symbol. The rail cannot afford
    /// the word "Constellation"; the dashboard shelf can.
    var iconOnly: Bool = false
    var accessibilityID: String?

    init(
        selection: Binding<Option>,
        options: [Option]? = nil,
        iconOnly: Bool = false,
        accessibilityID: String? = nil
    ) {
        self._selection = selection
        self.options = options ?? Array(Option.allCases)
        self.iconOnly = iconOnly
        self.accessibilityID = accessibilityID
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    Label(option.displayName, systemImage: option.symbolName)
                }
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: selection.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                if iconOnly == false {
                    Text(selection.displayName)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(accessibilityID ?? "")
        .accessibilityLabel("\(selection.displayName) view")
        .help("Change how this panel is shown")
    }
}
