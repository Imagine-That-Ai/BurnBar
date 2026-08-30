import SwiftUI
import AppKit
import OpenBurnBarCore

// MARK: - Memory (Pensieve) walkthrough content
//
// The single source of truth for what the walkthrough says. Kept as plain
// values so the copy is unit-testable and drifts loudly (tests pin the live
// endpoint and shim command against the Remote MCP card).

/// One page of the Memory walkthrough.
struct MemoryWalkthroughStep: Identifiable, Equatable {
    let id: Int
    let symbol: String
    /// Short all-caps kicker above the title.
    let eyebrow: String
    let title: String
    let body: String
    /// Example prompts or short supporting lines rendered as chips (optional).
    let chips: [String]
}

enum MemoryWalkthroughContent {
    /// The hosted endpoint every MCP-capable client can reach directly.
    static let endpoint = "https://mcp.burnbar.ai/mcp"
    /// The stdio shim for clients that cannot speak remote HTTP; also keeps
    /// decrypted previews on-device.
    static let shimCommand = "openburnbar-mcp-remote mcp serve"
    /// Diagnoses a broken link from Terminal.
    static let doctorCommand = "openburnbar mcp doctor"
    /// The guided setup page on the web.
    static let setupURL = URL(string: "https://burnbar.ai/product")!

    static let steps: [MemoryWalkthroughStep] = [
        MemoryWalkthroughStep(
            id: 0,
            symbol: "brain.head.profile",
            eyebrow: "Meet Memory",
            title: "Your AI chats, remembered.",
            body: "BurnBar quietly remembers what matters from your AI conversations — decisions, fixes, preferences, project facts — and hands them back to any AI tool you use. Everything is sealed with a key only your devices hold.",
            chips: []
        ),
        MemoryWalkthroughStep(
            id: 1,
            symbol: "checkmark.seal.fill",
            eyebrow: "Zero setup",
            title: "It saves itself.",
            body: "Sign in once with Cloud Pro and memory turns itself on. When a chat ends, BurnBar distills the useful facts and seals them with your vault key. It never interrupts a conversation and never spends your AI credits.",
            chips: []
        ),
        MemoryWalkthroughStep(
            id: 2,
            symbol: "point.3.connected.trianglepath.dotted",
            eyebrow: "Connect",
            title: "Plug in your other AI tools.",
            body: "Any MCP client — Codex, Claude Code, Droid, Kimi — can ask your memory questions. Tap “Link this Mac’s CLI” on the Remote MCP card and BurnBar configures supported tools for you, or copy these by hand:",
            chips: []
        ),
        MemoryWalkthroughStep(
            id: 3,
            symbol: "bubble.left.and.text.bubble.right.fill",
            eyebrow: "Recall",
            title: "Ask for anything back.",
            body: "In a connected tool — or in the BurnBar app on iPhone, iPad, and Android — just ask in plain words. Your assistant searches your sealed memory and decrypts the answer on your device.",
            chips: [
                "What do you remember about the auth refactor?",
                "Resume the conversation where we fixed the login bug.",
                "What did I decide about caching, and why?",
                "Summarize what we shipped this week.",
            ]
        ),
        MemoryWalkthroughStep(
            id: 4,
            symbol: "lock.shield.fill",
            eyebrow: "Control",
            title: "You're in control.",
            body: "Settings › Data & Privacy shows every record with a live “% sealed” gauge. Export everything as JSON, forget a single memory or a whole category, or hit Panic to revoke all access instantly.",
            chips: []
        ),
    ]
}

/// Clamped pager state for the walkthrough — extracted so navigation rules are
/// unit-testable without a SwiftUI harness.
struct MemoryWalkthroughPager: Equatable {
    private(set) var page: Int = 0
    let count: Int

    init(count: Int) {
        self.count = max(count, 1)
    }

    var canGoBack: Bool { page > 0 }
    var isLastPage: Bool { page >= count - 1 }

    mutating func advance() {
        page = min(page + 1, count - 1)
    }

    mutating func retreat() {
        page = max(page - 1, 0)
    }
}

// MARK: - Memory (Pensieve) walkthrough sheet

/// A five-page, under-a-minute modal that teaches the memory MCP end to end:
/// what memory is, that it saves itself, how to connect AI tools, how to
/// recall, and where the governance controls live. Presented from the Remote
/// MCP card in Settings › Cloud.
struct MemoryMCPWalkthroughView: View {
    @State private var pager = MemoryWalkthroughPager(count: MemoryWalkthroughContent.steps.count)
    /// Bumped when a copy row is tapped so the glyph flips to a checkmark briefly.
    @State private var copiedValue: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: MemoryWalkthroughStep {
        MemoryWalkthroughContent.steps[pager.page]
    }

    var body: some View {
        ZStack {
            EmberSurfaceBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(DesignSystem.Colors.borderSubtle)

                ScrollView {
                    pageContent(step)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(step.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                .frame(maxHeight: .infinity)

                Divider().overlay(DesignSystem.Colors.borderSubtle)
                footer
            }

            closeButton
        }
        .frame(width: 520, height: 580)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("MEMORY · PENSIEVE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(2.2)
                .foregroundStyle(PensieveTheme.brassCore)
            Spacer()
            Text("\(pager.page + 1) of \(pager.count)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Page content

    @ViewBuilder
    private func pageContent(_ step: MemoryWalkthroughStep) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            symbolBadge(step.symbol)

            VStack(alignment: .leading, spacing: 6) {
                Text(step.eyebrow.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.8)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(step.title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(step.body)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step.id == 2 {
                connectRows
            }

            if step.chips.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.chips, id: \.self) { chip in
                        Text("“\(chip)”")
                            .font(DesignSystem.Typography.caption)
                            .italic()
                            .foregroundStyle(DesignSystem.Colors.teal)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                    .fill(DesignSystem.Colors.teal.opacity(0.08))
                            )
                    }
                }
            }

            if step.id == 4 {
                controlActions
            }
        }
    }

    private func symbolBadge(_ symbol: String) -> some View {
        ZStack {
            Circle()
                .stroke(PensieveTheme.mercuryCore.opacity(0.6), lineWidth: 1)
                .frame(width: 64, height: 64)
            Circle()
                .fill(PensieveTheme.mercuryCore.opacity(0.12))
                .frame(width: 52, height: 52)
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PensieveTheme.mercuryBright)
        }
        .accessibilityHidden(true)
    }

    // MARK: Connect page (copyable rows)

    private var connectRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            copyRow(label: "Endpoint", value: MemoryWalkthroughContent.endpoint)
            copyRow(label: "Stdio shim", value: MemoryWalkthroughContent.shimCommand)
            copyRow(label: "Doctor", value: MemoryWalkthroughContent.doctorCommand)
            Text("Sealed results stay sealed until the shim decrypts them on this Mac. The cloud only ever sees scrambled data.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            HStack(spacing: 8) {
                Text(value)
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    copy(value)
                } label: {
                    Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copiedValue == value ? DesignSystem.Colors.success : DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(label)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                    )
            )
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        Task { [value] in
            try? await Task.sleep(for: .seconds(1.6))
            if copiedValue == value {
                copiedValue = nil
            }
        }
    }

    // MARK: Control page actions

    private var controlActions: some View {
        HStack(spacing: 16) {
            Link(destination: MemoryWalkthroughContent.setupURL) {
                HStack(spacing: 6) {
                    Text("Open Remote MCP setup")
                    Image(systemName: "arrow.up.right.square.fill")
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(PensieveTheme.brassCore)
            }
            Button {
                AppCommandRouter.shared.handleLinkCli()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                    Text("Link this Mac’s CLI")
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(PensieveTheme.brassCore)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Footer (dots + back/next)

    private var footer: some View {
        HStack {
            Button {
                withAnimation(motionAnimation) { pager.retreat() }
            } label: {
                Text("Back")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(pager.canGoBack ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(pager.canGoBack == false)
            .accessibilityLabel("Previous page")

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<pager.count, id: \.self) { index in
                    Circle()
                        .fill(index == pager.page ? PensieveTheme.brassCore : DesignSystem.Colors.textMuted.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)

            Spacer()

            if pager.isLastPage {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(PensieveTheme.brassCore)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Finish walkthrough")
            } else {
                Button {
                    withAnimation(motionAnimation) { pager.advance() }
                } label: {
                    Text("Next")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(PensieveTheme.brassCore)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Next page")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var motionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Spacer()
        }
    }
}

#Preview {
    MemoryMCPWalkthroughView()
}
