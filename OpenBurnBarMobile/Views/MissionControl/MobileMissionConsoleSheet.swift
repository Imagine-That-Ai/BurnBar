import SwiftUI
import OpenBurnBarCore

// MARK: - Mobile Mission Console Sheet
//
// Full-screen sheet host. Uses iOS 16+ presentationDetents with a near-full
// fraction so the user can dismiss with a quick pull-down. The sheet keeps
// the opaque app background on every OS version: `MissionControlConsoleView`
// paints `UnifiedDesignSystem.Colors.background` edge-to-edge itself (its
// `backdrop` base layer and its own `.background`), so a Liquid Glass sheet
// background would be fully occluded and an iOS 26 branch here would be
// inert. Revisit only if the console drops its opaque painting under
// `#available(iOS 26, *)`.

struct MobileMissionConsoleSheet: View {
    @Bindable var host: MobileMissionConsoleHost
    var onDismiss: () -> Void

    @State private var detent: PresentationDetent = .fraction(0.92)

    var body: some View {
        MissionControlConsoleView(host: host) {
            onDismiss()
        }
        .presentationDetents([.fraction(0.92), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(UnifiedDesignSystem.Colors.background)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
