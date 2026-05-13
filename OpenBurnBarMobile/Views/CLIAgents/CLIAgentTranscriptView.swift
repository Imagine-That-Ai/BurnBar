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
                    ForEach(liveSession.messages) { message in
                        bubble(for: message)
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
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(accent.opacity(0.10))
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
                    Text(message.text.isEmpty ? "…" : message.text)
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
                    toolStrip(message.toolUses)
                }
            }
            if !isUser { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder
    private func toolStrip(_ toolUses: [CLIAgentToolUse]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(toolUses) { tool in
                    toolPill(tool)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func toolPill(_ tool: CLIAgentToolUse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: tool.name))
                    .font(.system(size: 11, weight: .bold))
                Text(tool.name)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(tool.status)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            if let detail = tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                Text(detail)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(accent)
        .frame(maxWidth: 240, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(0.7), lineWidth: 0.75)
        )
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

    private func iconName(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("read") || n.contains("file") || n.contains("write") { return "doc.text" }
        if n.contains("bash") || n.contains("exec") || n.contains("run") || n.contains("terminal") { return "terminal" }
        if n.contains("search") || n.contains("grep") || n.contains("glob") || n.contains("find") { return "magnifyingglass" }
        if n.contains("web") || n.contains("browser") || n.contains("fetch") || n.contains("http") { return "globe" }
        if n.contains("edit") || n.contains("patch") || n.contains("replace") { return "pencil.and.outline" }
        if n.contains("memory") || n.contains("skill") || n.contains("learn") { return "brain" }
        if n.contains("image") || n.contains("vision") || n.contains("screenshot") { return "photo" }
        return "wrench.and.screwdriver.fill"
    }

    private var accent: Color {
        switch liveSession.agent {
        case .codex:    return Color(hex: "1ABC9C")
        case .claude:   return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        }
    }
}
