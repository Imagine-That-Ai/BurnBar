import SwiftUI

/// Phase 5 Mac incoming-call sheet. Full-window NSPanel with mercury
/// hairline, 96pt avatar with mercuryPulse, Decline / Accept buttons.
@MainActor
struct IncomingCallSheet: View {
    let pairedDeviceName: String
    let initial: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var pulseTrigger: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(borderGradient, lineWidth: 1.5)
                        .frame(width: 96, height: 96)
                        .scaleEffect(pulseTrigger ? 1.08 : 1.0)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseTrigger)
                    Text(initial)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(borderGradient)
                }
                Text(pairedDeviceName)
                    .font(.system(size: 20, weight: .semibold))
                Text("Pair-debug call")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                Button(role: .destructive) {
                    onDecline()
                } label: {
                    Text("Decline")
                        .frame(width: 120)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)

                Button {
                    onAccept()
                } label: {
                    Text("Accept")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color(red: 0.63, green: 0.67, blue: 0.73))
            }
        }
        .padding(40)
        .frame(minWidth: 380, minHeight: 320)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(borderGradient, lineWidth: 1)
                )
        )
        .onAppear { pulseTrigger.toggle() }
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
