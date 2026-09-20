import SwiftUI
import OpenBurnBarKernel

// MARK: - Receipt Settings View

struct ReceiptSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var onOpenDrawer: (() -> Void)?

    var body: some View {
        Form {
            Section {
                Toggle("Show Menu Bar Popup on CLI Close", isOn: $settingsManager.receiptFlyoutEnabled)
                    .help("Presents a transient mini-flyout below the menu bar icon when the CLI, terminal, or agent app actually closes")
                    .settingsAnchor(SettingsAnchor.receiptsOverview)

                Toggle("Send macOS Notification Banner", isOn: $settingsManager.receiptSystemNotificationsEnabled)
                    .help("Sends a native notification banner only after the conversation / terminal / app is closed — not after a quiet pause while the agent is still running")

                HStack {
                    Toggle("Play Thermal Printer Sound Effect", isOn: $settingsManager.receiptSoundEnabled)
                    Spacer()
                    Button {
                        ReceiptAudioPlayer.playReceiptPrintSound(enabled: true)
                    } label: {
                        Label("Preview", systemImage: "speaker.wave.2.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } header: {
                Label("Session Completion Popups", systemImage: "bell.badge.fill")
            } footer: {
                Text(
                    "A quiet minute is enough to print the slip. The flyout, thermal-printer " +
                    "sound, and banner wait until the CLI process, terminal job, or dedicated " +
                    "agent app is actually gone — Cursor.app staying open does not count, but " +
                    "cursor-agent does, even inside the Cursor.app bundle. The banner is silent; " +
                    "the thermal printer is the only close ping. The first banner asks for " +
                    "notification permission."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-Run Quality Review on Close", isOn: $settingsManager.receiptAutoQualityReviewEnabled)
                    .settingsAnchor(SettingsAnchor.receiptsQualityReview)
                    .help("Automatically evaluates Goal Completion, Rigor, and Efficiency with an A/B/C/D grade")

                Picker("Review Model", selection: $settingsManager.receiptReviewModel) {
                    Text("Claude 3.5 Haiku (Fast & Frugal)").tag("anthropic/claude-3.5-haiku")
                    Text("Claude 3.7 Sonnet (Deep Auditor)").tag("anthropic/claude-3.7-sonnet")
                    Text("GPT-4o Mini").tag("openai/gpt-4o-mini")
                    Text("Gemini 2.5 Flash").tag("google/gemini-2.5-flash")
                    Text("Heuristic Rubric (Offline & Free)").tag("heuristic-rubric")
                }
                .pickerStyle(.menu)
            } header: {
                Label("Quality Review & Rubric", systemImage: "checkmark.seal.fill")
            } footer: {
                Text("Grading assesses goal completion, tests executed, commit history, and token waste. You can always grade individual sessions manually from the thermal slip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let onOpenDrawer {
                Section {
                    Button(action: onOpenDrawer) {
                        Label("Open Full Receipts Register", systemImage: "scroll.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Receipts")
    }
}
