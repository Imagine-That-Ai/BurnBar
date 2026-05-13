import SwiftUI
import OpenBurnBarCore

// MARK: - CLI Agent Conversation List
//
// Replaces the "Connect your Mac" placeholder for the Codex, Claude
// Code, and OpenClaw tiles inside the iOS Assistants tab. Lists the
// mirrored sessions the macOS app has published into Firestore via
// `CLIAgentSessionMirror`. Read-only — tapping a row opens
// `CLIAgentTranscriptView`.
//
// Empty-state copy is intentional: if the user is signed in but hasn't
// chatted with this runtime on their Mac yet, we explain *why* the list
// is empty instead of inventing an "ask CLI agent" composer the iOS app
// can't drive.

struct CLIAgentConversationListView: View {
    let runtime: CLIAgentRuntime
    @State private var reader: CLIAgentChatReader = .shared
    @State private var selectedSession: CLIAgentSessionRecord?

    var body: some View {
        ZStack {
            AuroraBackdrop()

            if visibleSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle(runtime.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reader.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Refresh \(runtime.displayName) sessions")
                .disabled(reader.isLoading)
            }
        }
        .sheet(item: $selectedSession) { session in
            NavigationStack {
                CLIAgentTranscriptView(session: session)
                    .navigationTitle(session.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { selectedSession = nil }
                        }
                    }
            }
        }
        .task {
            await reader.refresh()
        }
        .refreshable {
            await reader.refresh()
        }
    }

    private var visibleSessions: [CLIAgentSessionRecord] {
        reader.sessions(for: runtime)
    }

    @ViewBuilder
    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: MobileTheme.Spacing.sm) {
                if let lastError = reader.lastError {
                    errorBanner(lastError)
                }
                ForEach(visibleSessions) { session in
                    Button {
                        selectedSession = session
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(MobileTheme.Spacing.md)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: CLIAgentSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if !session.isCompleted {
                    Text("live")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(accent.opacity(0.18))
                        )
                        .foregroundStyle(accent)
                }
            }
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let model = session.modelName, !model.isEmpty {
                    Label(model, systemImage: "cpu")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                if let workspace = session.workspaceLabel, !workspace.isEmpty {
                    Label(workspace, systemImage: "folder")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(accent.opacity(0.3), lineWidth: 0.7)
        )
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(MobileTheme.Typography.caption)
            .foregroundStyle(MobileTheme.Colors.error)
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(MobileTheme.Colors.error.opacity(0.12))
            )
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(accent.opacity(0.20))
                    .frame(width: 84, height: 84)
                Image(systemName: "command")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }
            VStack(spacing: 6) {
                Text("No \(runtime.displayName) sessions yet")
                    .font(MobileTheme.Typography.title)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(emptyCopy)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Button {
                Task { await reader.refresh() }
            } label: {
                Label(reader.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                    .font(MobileTheme.Typography.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .disabled(reader.isLoading)
            Spacer()
            Spacer()
        }
        .padding(MobileTheme.Spacing.lg)
    }

    private var emptyCopy: String {
        switch runtime {
        case .codex:
            return "Open OpenBurnBar on your Mac, chat with Codex, and your transcript — tool pills and all — will sync here automatically."
        case .claude:
            return "Open OpenBurnBar on your Mac and start a Claude Code session. Once it streams, this list mirrors the conversation."
        case .openClaw:
            return "Open OpenBurnBar on your Mac and start an OpenClaw session. The transcript appears here as it streams."
        }
    }

    private var accent: Color {
        switch runtime {
        case .codex:    return Color(hex: "1ABC9C")
        case .claude:   return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        }
    }
}

#Preview {
    NavigationStack {
        CLIAgentConversationListView(runtime: .codex)
    }
}
