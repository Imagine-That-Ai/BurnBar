import SwiftUI
import OpenBurnBarCore

// MARK: - Voice Intent Banner (Hermes Square §6.7)
//
// Drops in from the top after a voice command resolves. Shows the
// recognised intent + a tiny "Undo" affordance so the user can bail
// before the routing fires. Auto-dismisses after ~4.5s.

struct VoiceIntentBanner: View {
    let intent: VoiceIntent
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.callout.bold())
                .foregroundStyle(DesignSystemColors.ember)
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                Text(subhead)
                    .font(.caption2)
                    .foregroundStyle(DesignSystemColors.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .padding(8)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystemColors.surface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DesignSystemColors.ember.opacity(0.4), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .accessibilityElement(children: .combine)
    }

    private var glyph: String {
        switch intent {
        case .openAgent:                  return "arrow.right.circle.fill"
        case .search:                     return "magnifyingglass.circle.fill"
        case .dispatchMission:            return "paperplane.circle.fill"
        case .sendMessageToCurrentThread: return "bubble.right.fill"
        case .ambientBriefing:            return "sparkles"
        case .fallbackToHermes:           return "person.fill.questionmark"
        }
    }

    private var headline: String { intent.displayLabel }

    private var subhead: String {
        switch intent {
        case .openAgent(let uri):
            return uri
        case .search(let q):
            return "“\(q)”"
        case .dispatchMission(let prompt, let hint):
            if let hint, !hint.isEmpty { return "→ \(hint): \(prompt)" }
            return prompt
        case .sendMessageToCurrentThread(let text):
            return text
        case .ambientBriefing:
            return "Asking Hermes for the brief…"
        case .fallbackToHermes(let text):
            return text.isEmpty ? "Heard nothing — try again." : text
        }
    }
}
