import SwiftUI

/// First-run opt-in prompt for usage analytics. Analytics is **off by default**;
/// this prompt records the user's decision in `AnalyticsConsentStore.shared` and,
/// on grant, notifies `Analytics.shared` to start the SDK. It is revisitable any
/// time from Settings → Privacy ("Share Usage Analytics").
struct AnalyticsConsentPromptView: View {
    /// `true` to grant, `false` to decline. The caller persists the decision and
    /// dismisses the prompt.
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Help improve OpenBurnBar")
                    .font(.title2.weight(.semibold))
            }

            Text("Share privacy-preserving usage analytics so we can see which features matter and where flows break. This is off by default — you can change it anytime in Settings → Privacy.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Label("Never your conversations, prompts, API keys, secrets, or file paths", systemImage: "lock.fill")
                Label("Only feature names, outcomes, and bucketed counts", systemImage: "checkmark.seal.fill")
                Label("Sent only after you opt in; stops the moment you turn it off", systemImage: "hand.raised.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Not now") { onDecision(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Enable analytics") { onDecision(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 460)
    }
}
