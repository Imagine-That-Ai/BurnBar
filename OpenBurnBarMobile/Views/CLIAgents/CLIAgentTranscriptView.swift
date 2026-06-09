import SwiftUI
import OpenBurnBarCore

// MARK: - CLI Agent Transcript View
//
// Read-only renderer for one mirrored CLI agent session. Reuses the
// same visual vocabulary as the Hermes message bubbles (user pill on
// the right, assistant pill on the left, tool strip below) so the iOS
// chat tabs feel coherent across runtimes.
//
// Pulled from `CLIAgentChatReader.session(id:)` so live updates from
// the Mac's mirror upserts surface immediately as the user is reading.

struct CLIAgentTranscriptView: View {
    let session: CLIAgentSessionRecord
    @State private var reader: CLIAgentChatReader = .shared

    /// Always prefer the freshest snapshot the reader has — keeps the
    /// view consistent if Firestore upserts arrive while it's open.
    private var liveSession: CLIAgentSessionRecord {
        reader.session(id: session.id) ?? session
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                    metadataBanner
                    if liveSession.messages.isEmpty, liveSession.sourceKind == .archivedLog {
                        archivedLogBanner
                    } else {
                        ForEach(liveSession.messages) { message in
                            bubble(for: message)
                        }
                    }
                    if !liveSession.isCompleted {
                        liveIndicator
                    }
                }
                .padding(MobileTheme.Spacing.lg)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await reader.refresh() }
    }

    @ViewBuilder
    private var metadataBanner: some View {
        let session = liveSession
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.agent.displayName)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(accent)
                if let model = session.modelName, !model.isEmpty {
                    Text("·")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Text(model)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }
                Spacer()
                if let usage = session.tokenUsage, usage.totalTokens > 0 {
                    Text("\(usage.totalTokens) tok")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .monospacedDigit()
                }
            }
            if let workspace = session.workspaceLabel, !workspace.isEmpty {
                Label(workspace, systemImage: "folder")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            if session.sourceKind == .archivedLog {
                Label("Encrypted cloud archive", systemImage: "lock.doc")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(accent.opacity(0.10))
        )
    }

    @ViewBuilder
    private var archivedLogBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Archived provider session", systemImage: "lock.doc")
                .font(MobileTheme.Typography.body.weight(.semibold))
                .foregroundStyle(accent)
            Text(liveSession.encryptedTranscriptAvailable
                 ? "The full transcript is stored in your encrypted cloud session log index. Search Hermes Square to open matching encrypted snippets."
                 : "This session was indexed from the paired Mac.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            if let handle = liveSession.resumeHandle {
                VStack(alignment: .leading, spacing: 4) {
                    if handle.canResume {
                        Text("Resume on Mac")
                            .font(MobileTheme.Typography.tiny.weight(.semibold))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    if let command = handle.commandHint {
                        Text(command)
                            .font(MobileTheme.Typography.tiny.monospaced())
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(accent.opacity(0.45), lineWidth: 0.7)
        )
    }

    @ViewBuilder
    private func bubble(for message: CLIAgentMessage) -> some View {
        let isUser = message.role == .user
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            if isUser { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                if !isUser {
                    Text("via \(liveSession.agent.displayName)")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(accent)
                }
                if !message.text.isEmpty || message.toolUses.isEmpty {
                    // Assistant turns arrive as markdown — render inline
                    // emphasis instead of raw `**` markers. User and error
                    // turns stay verbatim.
                    Text(
                        isUser || message.isError || message.text.isEmpty
                            ? AttributedString(message.text.isEmpty ? "…" : message.text)
                            : HermesInlineMarkdown.attributedString(message.text)
                    )
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(message.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
                        .padding(.horizontal, MobileTheme.Spacing.md)
                        .padding(.vertical, MobileTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                .fill(MobileTheme.Colors.surfaceElevated)
                                .overlay(
                                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                        .strokeBorder(accent.opacity(0.4), lineWidth: 0.7)
                                )
                        )
                }
                if !message.toolUses.isEmpty {
                    UnifiedToolCallAccordion(calls: unifiedToolCalls(for: message), accent: .agent(accent))
                }
            }
            if !isUser { Spacer(minLength: 32) }
        }
    }

    /// Maps a mirrored CLI agent message's tool uses into the shared display
    /// model. CLI runtimes report an honest per-call status, so the status
    /// string drives the running pulse — `isRunning` stays false here.
    private func unifiedToolCalls(for message: CLIAgentMessage) -> [UnifiedToolCallDisplay] {
        message.toolUses.map { tool in
            UnifiedToolCallDisplay(
                id: tool.id,
                name: tool.name,
                statusRaw: tool.status,
                detail: tool.detail
            )
        }
    }

    private var liveIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            Text("live on your Mac…")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(accent)
        }
        .padding(.leading, MobileTheme.Spacing.sm)
    }

    private var accent: Color {
        switch liveSession.agent {
        case .codex:    return Color(hex: "1ABC9C")
        case .claude:   return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        case .droid:    return Color(hex: "8B5CF6")
        case .forge:    return Color(hex: "F97316")
        case .antigravity: return Color(hex: "6C63FF")
        case .grok: return Color(hex: "E0E0E0")  // Grok monochrome brand — light gray legible in dark mode
        case .cursorAgent: return Color(hex: "00E5FF")
        }
    }
}
