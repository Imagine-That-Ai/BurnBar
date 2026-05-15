import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Quick Ask Card
//
// In-place 3-message thread on Pulse. Tap into it to expand → opens the
// Hermes tab via the provided `onOpen` callback. Inline strip is backed
// by the same `HermesService` used by the dedicated tab.

struct HermesQuickAskCard: View {
    @Bindable var service: HermesService
    let suggestedPrompts: [String]
    let onOpenHermes: () -> Void

    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                AuroraSection(
                    "Hermes",
                    subtitle: isHermesUsable
                        ? "Live · ask about your fleet"
                        : "Hermes offline — start it on your Mac",
                    accent: isHermesUsable ? MobileTheme.hermesAureate : MobileTheme.warning
                ) {
                    Button(action: onOpenHermes) {
                        Label("Full chat", systemImage: "arrow.up.right.square")
                            .labelStyle(.titleAndIcon)
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.hermesAureate)
                    }
                    .buttonStyle(.plain)
                }

                threadPreview
                MercuryDivider()
                inputRow
                if input.isEmpty {
                    promptRail
                }
            }
        }
    }

    private var isHermesUsable: Bool {
        HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: service.isReachable,
            selectedConnection: service.selectedConnection,
            suggestedRelayConnection: service.suggestedRelayConnection
        )
    }

    // MARK: - Thread Preview

    @ViewBuilder
    private var threadPreview: some View {
        let recent = Array(service.messages.suffix(3))
        if recent.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                HermesLiveGlyph(size: 24, isLive: service.isStreaming)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask about your burn")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Hermes can summarize today's spend, find your most expensive sessions, or forecast EOD usage.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(recent) { msg in
                    HStack(alignment: .top, spacing: 6) {
                        Group {
                            if msg.role == .user {
                                Text("You")
                                    .font(MobileTheme.Typography.tiny)
                                    .fontWeight(.bold)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            } else {
                                HermesLiveGlyph(size: 14, isLive: msg.isStreaming)
                            }
                        }
                        .frame(width: 28, alignment: .leading)
                        Text(msg.text)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(2)
                    }
                }
                if service.isStreaming {
                    MercuryThinkingIndicator()
                        .padding(.leading, 26)
                }
            }
        }
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Ask Hermes about your burn…", text: $input, axis: .horizontal)
                .font(MobileTheme.Typography.body)
                .textFieldStyle(.plain)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .focused($inputFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(input.isEmpty ? MobileTheme.Colors.textMuted : MobileTheme.hermesAureate)
                    .symbolEffect(.bounce, value: input.isEmpty ? 0 : 1)
            }
            .buttonStyle(.plain)
            .disabled(input.isEmpty || service.isStreaming)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            inputFocused ? MobileTheme.hermesAureate : MobileTheme.Colors.border.opacity(0.4),
                            lineWidth: inputFocused ? 1.0 : 0.5
                        )
                )
        )
    }

    // MARK: - Prompt Rail

    private var promptRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        input = prompt
                        send()
                    } label: {
                        Text(prompt)
                            .font(MobileTheme.Typography.tiny)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(MobileTheme.hermesAureate)
                            .background(
                                Capsule()
                                    .fill(MobileTheme.hermesAureate.opacity(0.12))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(MobileTheme.hermesAureate.opacity(0.35), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Send

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        HapticBus.send()
        input = ""
        service.sendMessage(trimmed)
    }
}
