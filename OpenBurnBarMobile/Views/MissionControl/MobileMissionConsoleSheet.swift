import SwiftUI
import OpenBurnBarCore

// MARK: - Mobile Mission Console Sheet
//
// Full-screen sheet host. Uses iOS 16+ presentationDetents with a near-full
// fraction so the user can dismiss with a quick pull-down. On iOS 26+ the
// shared `MissionControlConsoleView` already adopts Liquid Glass surfaces;
// here we just provide the sheet shell.

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
