import SwiftUI
import AppKit
import OpenBurnBarUI

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
    /// Where to find the thing this page is about (nil for purely conceptual pages).
    let tourAnchor: String?
    /// Human-readable breadcrumbs for the spotlight preview.
    let findPath: String?
    /// Miniature preview of the destination rendered inside the spotlight card.
    /// Nil on pages without a spotlight. Kept in the content layer so tests can
    /// pin the preview copy against the destination it promises.
    let previewIcon: String?
    let previewTitle: String?
    let previewSubtitle: String?

    init(
        id: Int,
        symbol: String,
        eyebrow: String,
        title: String,
        body: String,
        chips: [String],
        tourAnchor: String?,
        findPath: String?,
        previewIcon: String? = nil,
        previewTitle: String? = nil,
        previewSubtitle: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.eyebrow = eyebrow
        self.title = title
        self.body = body
        self.chips = chips
        self.tourAnchor = tourAnchor
        self.findPath = findPath
        self.previewIcon = previewIcon
        self.previewTitle = previewTitle
        self.previewSubtitle = previewSubtitle
    }
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
    /// The member's web console — where sealed data is visible and governed
    /// from any browser, not just this Mac.
    static let consoleURL = MacCloudConsoleURLs.pensieve

    static let steps: [MemoryWalkthroughStep] = [
        MemoryWalkthroughStep(
            id: 0,
            symbol: "brain.head.profile",
            eyebrow: "Meet Memory",
            title: "Your AI chats, remembered.",
            body: "Hello — I'm Pensieve, BurnBar's memory basin. I quietly remember what matters from your AI conversations — decisions, fixes, preferences, project facts — and hand them back to any AI tool you use. Everything is sealed with a key only your devices hold.",
            chips: [],
            tourAnchor: nil,
            findPath: nil
        ),
        MemoryWalkthroughStep(
            id: 1,
            symbol: "checkmark.seal.fill",
            eyebrow: "On this Mac",
            title: "It saves itself — once you say yes.",
            body: "Memory runs on this Mac, no account needed. Nothing is read until you allow it: OpenBurnBar asks first, then I distill the useful facts — decisions, fixes, preferences — and keep them sealed locally. On/off, high-recall, review, and reset live here, free for everyone.",
            chips: [],
            tourAnchor: SettingsAnchor.indexingMemory,
            findPath: "Settings › General › Indexing",
            previewIcon: "brain.head.profile",
            previewTitle: "Memory controls",
            previewSubtitle: "On-device · consent first · review or reset anytime"
        ),
        MemoryWalkthroughStep(
            id: 2,
            symbol: "point.3.connected.trianglepath.dotted",
            eyebrow: "Connect",
            title: "Plug in your other AI tools.",
            body: "Any MCP client — Codex, Claude Code, Droid, Kimi — can ask your memory questions. Tap \"Link this Mac's CLI\" on the Remote MCP card and BurnBar configures supported tools for you, or copy these by hand:",
            chips: [],
            tourAnchor: SettingsAnchor.cloudRemoteMCPConnect,
            findPath: "Settings › Cloud › Remote MCP",
            previewIcon: "point.3.connected.trianglepath.dotted",
            previewTitle: "Remote MCP",
            previewSubtitle: "Link this Mac's CLI  ·  Endpoint  ·  Doctor"
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
                "Summarize what we shipped this week."
            ],
            tourAnchor: nil,
            findPath: nil
        ),
        MemoryWalkthroughStep(
            id: 4,
            symbol: "lock.shield.fill",
            eyebrow: "Control",
            title: "You're in control.",
            body: """
            Everything I keep is yours to inspect. Review pending memories, reset them, \
            or opt into sealed cloud backup in Settings › General › Indexing — free for everyone. \
            With Cloud Pro, Settings › Data & Privacy opens the full Pensieve workbench: \
            every record with a live \"% sealed\" gauge, JSON export, forgetting, and Panic. \
            The same control lives on the web at app.burnbar.ai.
            """,
            chips: [],
            tourAnchor: SettingsAnchor.dataControlCenterInventory,
            findPath: "Settings › Data & Privacy",
            previewIcon: "lock.shield.fill",
            previewTitle: "Data & Privacy Control Center",
            previewSubtitle: "Every record · Export · Forget · Panic (Cloud Pro)"
        )
    ]
}

/// Opens the right Settings page for a walkthrough spotlight anchor.
///
/// Uses the manifest + deep-link routing so the destination scrolls and
/// highlights exactly the same row the walkthrough previews.
enum MemoryWalkthroughNavigator {
    static func show(anchor: String) {
        guard let item = SettingsManifest.all.first(where: { $0.anchorID == anchor }) else { return }
        Task { @MainActor in
            _ = SettingsDeepLinkRouting.route(to: item.id)
            // Also ensure Settings itself is open — AppCommandRouter is the
            // canonical opener; if the app is already showing Settings this
            // is a no-op and the router notification does the navigation.
            AppCommandRouter.shared.openSettings?()
        }
    }
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

/// A five-page, under-a-minute guided tour that teaches the memory MCP end to
/// end — with a friendly Pensieve voice, copyable connection rows, and
/// "Show me" buttons that spotlight and drive the user to the real Settings
/// controls. Presented from Settings › Cloud › Remote MCP, the Help menu, and
/// Settings search ("memory tour").
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

            if let anchor = step.tourAnchor, let path = step.findPath {
                spotlightPreview(step: step, anchor: anchor, path: path)
            }

            if step.id == 2 {
                connectRows
            }

            if step.chips.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.chips, id: \.self) { chip in
                        Text("\"\(chip)\"")
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

    // MARK: Spotlight preview (where to find it + Show me)

    private func spotlightPreview(step: MemoryWalkthroughStep, anchor: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PensieveTheme.brassCore)
                Text("Find it at \(path)")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Button {
                    routeToSpotlight(anchor)
                } label: {
                    HStack(spacing: 4) {
                        Text("Show me")
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PensieveTheme.brassCore)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(path) in Settings")
            }

            // Miniature preview that mirrors the real card's shape with a
            // warm amber halo — the same highlight SettingsAnchorModifier
            // paints on arrival.
            HStack(spacing: 10) {
                Image(systemName: step.previewIcon ?? "scope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PensieveTheme.brassCore)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(PensieveTheme.brassCore.opacity(0.14))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.previewTitle ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(step.previewSubtitle ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.amber.opacity(0.35), lineWidth: 1)
                    .shadow(color: DesignSystem.Colors.amber.opacity(0.18), radius: 8, y: 2)
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.amber.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(DesignSystem.Colors.amber.opacity(0.18), lineWidth: 0.5)
        )
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
            Link(destination: MemoryWalkthroughContent.setupURL) {
                HStack(spacing: 6) {
                    Text("Open the guided setup page")
                    Image(systemName: "arrow.up.right.square.fill")
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(PensieveTheme.brassCore)
            }
            .accessibilityLabel("Open the guided Remote MCP setup page")
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

    /// Step 4's verbs. "Open the Pensieve" routes to the Data & Privacy deep
    /// link, which opens the workbench outright when the member holds the
    /// vault tier and otherwise lands on the landing's free-options card.
    /// "Open my Memory controls" goes straight to the on-device controls that
    /// work for everyone, no account required. "Open Pensieve online" hands
    /// the member to the web console, where the same data is visible and
    /// governable from any browser.
    private var controlActions: some View {
        HStack(spacing: 16) {
            Button {
                routeToSpotlight(SettingsAnchor.dataControlCenterInventory)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                    Text("Open the Pensieve")
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(PensieveTheme.brassCore)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the Pensieve workbench in Settings")

            Button {
                routeToSpotlight(SettingsAnchor.indexingMemory)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Open my Memory controls")
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(PensieveTheme.brassCore)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open on-device Memory controls in Settings")

            Link(destination: MemoryWalkthroughContent.consoleURL) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text("Open Pensieve online")
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(PensieveTheme.brassCore)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the Pensieve console at app.burnbar.ai in your browser")
        }
    }

    /// Dismiss the sheet, then drive Settings to the anchor once the dismiss
    /// animation has had a tick to settle.
    private func routeToSpotlight(_ anchor: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            MemoryWalkthroughNavigator.show(anchor: anchor)
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
