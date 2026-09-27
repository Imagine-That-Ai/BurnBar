import SwiftUI

// MARK: - First-run memory content
//
// The single source of truth for what the first-run memory step says. Kept as
// plain values (the same shape `MemoryWalkthroughContent` uses) so every
// sentence is unit-testable and drifts loudly.
//
// Every claim below is pinned to `tools/openburnbar-mcp/README.md`:
//   * "lives on this Mac" / encrypted — §Privacy ("Everything stays on this
//     machine … never uploaded") and §Encrypted at rest (AES-256-GCM).
//   * "nothing is collected until you say yes" — automatic collection is the
//     `SessionEnd` hook the member installs themselves; in-app extraction is
//     consent-gated.
//   * "a connected agent does the remembering" — memories are written by
//     `burnbar_remember` / `burnbar_memorize`, i.e. by a connected client.
//   * "nothing is pruned for you" — there is no background pruner; `expires_at`
//     is optional and set by the writer, and removal is `burnbar_memory_review`
//     / `burnbar_forget` / `burnbar_forget_all`.

/// One plain-language fact about how memory behaves on this Mac.
struct OnboardingMemoryFact: Identifiable, Equatable {
    let id: Int
    let symbol: String
    let title: String
    let body: String
}

enum OnboardingMemoryContent {
    static let title = "Memory for your agents"

    static let subtitle = "OpenBurnBar can keep the durable facts from your AI coding sessions \u{2014} decisions, fixes, preferences \u{2014} and hand them back to any agent you connect."

    static let facts: [OnboardingMemoryFact] = [
        OnboardingMemoryFact(
            id: 0,
            symbol: "internaldrive",
            title: "It lives on this Mac.",
            body: "Memories are written to OpenBurnBar's local store and encrypted at rest. No account is needed, and your transcripts are read here, not uploaded."
        ),
        OnboardingMemoryFact(
            id: 1,
            symbol: "hand.raised",
            title: "Nothing is collected until you say yes.",
            body: "By itself, OpenBurnBar writes no memories. Collecting them automatically at the end of a Claude Code session is a hook you install on purpose, and in-app extraction waits for your consent."
        ),
        OnboardingMemoryFact(
            id: 2,
            symbol: "point.3.connected.trianglepath.dotted",
            title: "A connected agent does the remembering.",
            body: "Memories are saved when an agent decides a fact is worth keeping, and searched when you ask it a question. Connect one below \u{2014} until then, nothing is written and nothing is read."
        ),
        OnboardingMemoryFact(
            id: 3,
            symbol: "tray.full",
            title: "Nothing is pruned for you.",
            body: "Memories stay until you remove them, and one expires only if whoever wrote it set an expiry. Review, forget, or bulk-delete them in Settings \u{203A} Data & Privacy."
        )
    ]

    /// The step is optional; say where everything on it lives afterwards.
    static let skipNote = "Skip this and nothing is lost \u{2014} the same installer lives in Settings \u{203A} Agents \u{203A} CLIs, and memory collection is switched on in Settings \u{203A} General \u{203A} Indexing."

    // MARK: Learn more

    /// The long form of exactly these four facts, on the web. `#duties` is the
    /// "Four questions, before the config block" section of
    /// `website/src/pages/memory.astro` — the same four questions this step
    /// answers, with the per-surface detail a first run has no room for.
    ///
    /// Deliberately a link and not a step: it opens in the member's browser, it
    /// is never the way forward, and the step works with no network at all —
    /// nothing here is fetched, the copy above is compiled in.
    static let learnMoreURL = URL(string: "https://burnbar.ai/memory#duties")!

    static let learnMoreTitle = "Read the long version at burnbar.ai/memory"

    static let learnMoreAccessibilityLabel = "Read the long version of how memory works at burnbar.ai/memory, opens in your browser"
}

// MARK: - First-run memory step

/// The onboarding step that makes the Memory MCP legible to somebody opening
/// OpenBurnBar for the first time: what the memory is, where it lives, what
/// happens on its own (nothing), what needs a coding agent connected, and who
/// does the pruning (they do).
///
/// Reuses `MCPInstallCard` rather than inventing a second installer, so the
/// row states, the file-path disclosure, and the "no server resolved" reason
/// are the same ones Settings shows.
struct OnboardingMemoryView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(OnboardingMemoryContent.title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(OnboardingMemoryContent.subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                            ForEach(OnboardingMemoryContent.facts) { fact in
                                factRow(fact)
                            }
                        }
                        .padding(DesignSystem.Spacing.sm)
                    }

                    MCPInstallCard()
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                learnMoreLink

                Text(OnboardingMemoryContent.skipNote)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One quiet way out to the long form. Sits with the skip note rather than
    /// with the wizard's buttons so it never reads as the next action, and
    /// follows the same `Link` + arrow idiom the Settings memory walkthrough
    /// uses for its own outbound page.
    private var learnMoreLink: some View {
        Link(destination: OnboardingMemoryContent.learnMoreURL) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(OnboardingMemoryContent.learnMoreTitle)
                Image(systemName: "arrow.up.right.square.fill")
            }
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.ember)
        }
        .accessibilityLabel(OnboardingMemoryContent.learnMoreAccessibilityLabel)
    }

    @ViewBuilder
    private func factRow(_ fact: OnboardingMemoryFact) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: fact.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.ember)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(fact.body)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
