import SwiftUI

/// Phase 3 popover-header entry point: the Mercury-stroked "Start mirror"
/// button. Click produces a confirmation dialog ("Mirror to Alberto's
/// iPhone? · 1920×1080 · ≤60 min") with Cancel / Start.
@MainActor
struct StartMirrorButton: View {
    @State private var isConfirming: Bool = false
    let isPaired: Bool
    let isCoolingDown: Bool
    let cooldownSecondsRemaining: Int
    let pairedDeviceName: String?
    let onStart: () -> Void

    private var isEnabled: Bool {
        isPaired && !isCoolingDown
    }

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(borderGradient, lineWidth: 1)
                    .frame(width: 24, height: 24)
                Image(systemName: "play.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(borderGradient)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .overlay(alignment: .bottomTrailing) {
                if isCoolingDown {
                    Text("\(cooldownSecondsRemaining)s")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.thinMaterial, in: Capsule())
                        .offset(x: 6, y: 6)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isPaired ? "Mirror this Mac's screen to your paired iPhone" : "Pair an iPhone first")
        .confirmationDialog(
            "Mirror to \(pairedDeviceName ?? "your iPhone")?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Start mirror") { onStart() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("1920×1080 · HEVC · 8 Mbps · ≤60 min")
        }
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
