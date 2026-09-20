import AppKit
import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Transcript lens

/// The receipts inspector's chat view, printed as a continuation of the
/// thermal slip: serrated tape, orange ink for Alberto, harness stamp for
/// the agent, and the same Session Logs link the banner tap uses.
struct ReceiptTranscriptLensView: View {
    let receipt: ReceiptRecord
    var overlay: ReceiptConversationOverlay?
    var dataStore: DataStore?
    var onCopied: ((String) -> Void)?

    @State private var transcript: ConversationRecord?
    @State private var loadState: LoadState = .idle
    @State private var showFullTape = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case missing
        case failed(String)
    }

    private var conversationID: String {
        ReceiptChatBridge.conversationID(receipt: receipt, overlay: overlay)
    }

    private var summary: String {
        ReceiptChatBridge.contentSummary(
            receipt: receipt,
            overlay: overlay,
            transcript: transcript
        )
    }

    private var paperBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.12, blue: 0.13)
            : Color(red: 0.98, green: 0.98, blue: 0.97)
    }

    private var paperBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    var body: some View {
        VStack(spacing: 0) {
            SerratedEdgeShape(toothCount: 22, toothHeight: 4, isTop: true)
                .fill(paperBackground)
                .frame(height: 4)

            VStack(alignment: .leading, spacing: 12) {
                tapeHeader
                dashedRule
                summaryBlock
                dashedRule
                transcriptBody
                dashedRule
                linkRow
            }
            .padding(14)
            .background(paperBackground)

            SerratedEdgeShape(toothCount: 22, toothHeight: 4, isTop: false)
                .fill(paperBackground)
                .frame(height: 4)
        }
        .overlay(
            Rectangle()
                .stroke(paperBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 8, y: 3)
        .frame(maxWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat tape for \(receipt.projectName)")
        .task(id: tapeLoadKey) {
            await loadTranscript()
        }
    }

    /// Overlay often hydrates after first paint. Reload when the join key arrives
    /// so Chat tape does not stick on NO TAPE.
    private var tapeLoadKey: String {
        let keys = ReceiptChatBridge.conversationLookupKeys(receipt: receipt, overlay: overlay)
        return ([receipt.id] + keys).joined(separator: "|")
    }

    // MARK: Header

    private var tapeHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CHAT TAPE")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.orange)
                Text(receipt.harness.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(ReceiptHarnessInk.color(for: receipt.provider))
            }
            Spacer()
            if let count = displayedMessageCount, count > 0 {
                Text("\(count) TURNS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var dashedRule: some View {
        ReceiptDashedDivider()
    }

    // MARK: Summary

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WHAT THIS CHAT WAS ABOUT")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            if summary.isEmpty {
                Text("No summary yet. The tape below still opens once the indexer has the session.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text(summary)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayedMessageCount: Int? {
        if let transcript, transcript.messageCount > 0 { return transcript.messageCount }
        if let overlay, overlay.messageCount > 0 { return overlay.messageCount }
        return nil
    }

    // MARK: Links

    private var linkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReceiptLinkButton(
                title: "Open in Session Logs",
                systemImage: "text.bubble",
                help: "Jump to this chat in Session Logs"
            ) {
                openSessionLogs()
            }
            .accessibilityHint("Opens the full session log for this receipt")

            if transcript?.fullText.isEmpty == false {
                ReceiptLinkButton(
                    title: "Copy full transcript",
                    systemImage: "doc.on.doc",
                    help: "Copy the indexed chat body"
                ) {
                    copy(transcript?.fullText ?? "", toast: "Transcript copied")
                }
            }

            if let url = ReceiptChatBridge.sessionURL(conversationID: conversationID) {
                ReceiptLinkButton(
                    title: "Copy chat link",
                    systemImage: "link",
                    help: url.absoluteString
                ) {
                    copy(url.absoluteString, toast: "Chat link copied")
                }
            }

            if let url = ReceiptChatBridge.receiptURL(receiptID: receipt.id) {
                ReceiptLinkButton(
                    title: "Copy slip link",
                    systemImage: "scroll",
                    help: url.absoluteString
                ) {
                    copy(url.absoluteString, toast: "Slip link copied")
                }
            }

            if let folder = ReceiptChatBridge.revealURL(
                workingDirectory: overlay?.workingDirectory ?? transcript?.workingDirectory
            ) {
                ReceiptLinkButton(
                    title: "Reveal project folder",
                    systemImage: "folder",
                    help: folder.path
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }

            let files = touchedFiles
            if !files.isEmpty {
                ForEach(Array(files.prefix(6)), id: \.self) { file in
                    ReceiptLinkButton(
                        title: file,
                        systemImage: "doc",
                        help: "Reveal \(file)"
                    ) {
                        if let url = ReceiptChatBridge.revealURL(
                            workingDirectory: overlay?.workingDirectory ?? transcript?.workingDirectory,
                            relativePath: file
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            copy(file, toast: "Path copied")
                        }
                    }
                }
            }
        }
    }

    private var touchedFiles: [String] {
        if !receipt.filesTouched.isEmpty { return receipt.filesTouched }
        return overlay?.keyFiles ?? []
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptBody: some View {
        switch loadState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Printing transcript…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityLabel("Loading transcript")
        case .missing:
            missingState(
                title: "NO TAPE ON FILE",
                detail: "This session is not indexed yet. Session Logs may still have the file under another id."
            )
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                missingState(title: "TAPE JAM", detail: message)
                Button("Try again") {
                    Task { await loadTranscript() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Retry loading transcript")
            }
        case .loaded:
            let blocks = TranscriptBlockParser.parse(transcript?.fullText ?? "")
            if blocks.isEmpty {
                if let raw = transcript?.fullText, !raw.isEmpty {
                    Text(ReceiptChatBridge.compressSummary(raw, maxCharacters: 1_800))
                        .font(.system(size: 11.5, design: .rounded))
                        .textSelection(.enabled)
                } else {
                    missingState(
                        title: "BLANK TAPE",
                        detail: "The session is indexed but the transcript body is empty."
                    )
                }
            } else {
                let spoken = ReceiptTranscriptTape.spokenBlocks(blocks)
                let visible = showFullTape
                    ? ReceiptTranscriptTape.fullTapeBlocks(blocks)
                    : spoken
                let clipped = showFullTape
                    ? ReceiptTranscriptTape.omittedFullTapeCount(blocks)
                    : 0
                VStack(alignment: .leading, spacing: 8) {
                    if spoken.count > 12 && !showFullTape {
                        tapeTurns(Array(spoken.prefix(6)))
                        omittedMarker(spoken.count - 12)
                        tapeTurns(Array(spoken.suffix(6)))
                        Button("Show full tape") {
                            showFullTape = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Show the full transcript")
                    } else {
                        tapeTurns(visible)
                        if clipped > 0 {
                            omittedMarker(clipped)
                        }
                        if spoken.count > 12 && showFullTape {
                            Button("Collapse tape") {
                                showFullTape = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Collapse the transcript")
                        }
                    }
                }
            }
        }
    }

    private func missingState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                .foregroundStyle(.orange)
            Text(detail)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func omittedMarker(_ count: Int) -> some View {
        Text("··· \(count) TURNS ON THE FULL TAPE ···")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .accessibilityLabel("\(count) turns omitted. Show full tape to read them here.")
    }

    private func tapeTurns(_ blocks: [TranscriptBlock]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                transcriptLine(block)
            }
        }
    }

    @ViewBuilder
    private func transcriptLine(_ block: TranscriptBlock) -> some View {
        switch block.kind {
        case .toolUse, .codeBlock:
            toolChip(block)
        default:
            spokenLine(block)
        }
    }

    private func spokenLine(_ block: TranscriptBlock) -> some View {
        let isUser = block.kind == .userMessage
        let ink = isUser ? Color.orange : ReceiptHarnessInk.color(for: receipt.provider)
        return VStack(alignment: .leading, spacing: 4) {
            Text(isUser ? "YOU" : roleLabel(block).uppercased())
                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(ink)
            Text(ReceiptChatBridge.compressSummary(block.content, maxCharacters: 900))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(ink.opacity(0.08))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ink)
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : roleLabel(block)): \(ReceiptChatBridge.compressSummary(block.content, maxCharacters: 160))")
    }

    private func toolChip(_ block: TranscriptBlock) -> some View {
        let ink = ReceiptHarnessInk.color(for: receipt.provider)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: block.kind == .codeBlock ? "chevron.left.forwardslash.chevron.right" : "wrench.and.screwdriver")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ink)
            Text(roleLabel(block))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(ink)
            if !block.content.isEmpty {
                Text(ReceiptChatBridge.compressSummary(block.content, maxCharacters: 80))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ink.opacity(0.06))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(roleLabel(block)): \(ReceiptChatBridge.compressSummary(block.content, maxCharacters: 80))")
    }

    private func roleLabel(_ block: TranscriptBlock) -> String {
        switch block.kind {
        case .userMessage: return "You"
        case .assistantMessage: return receipt.harness
        case .toolUse: return block.label ?? "Tool"
        case .codeBlock: return block.label ?? "Code"
        case .separator: return ""
        }
    }

    // MARK: Actions

    private func openSessionLogs() {
        guard let url = ReceiptChatBridge.sessionURL(conversationID: conversationID) else { return }
        ReceiptDeepLink.open(url)
    }

    private func copy(_ string: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        onCopied?(toast)
    }

    private func loadTranscript() async {
        let requested = tapeLoadKey
        transcript = nil
        showFullTape = false
        loadState = .loading
        guard let dataStore else {
            loadState = .missing
            return
        }
        do {
            var record: ConversationRecord?
            for key in ReceiptChatBridge.conversationLookupKeys(receipt: receipt, overlay: overlay) {
                if let hit = try await dataStore.fetchConversationForReceipt(sessionId: key) {
                    record = hit
                    break
                }
            }
            guard !Task.isCancelled, requested == tapeLoadKey else { return }
            if let record {
                transcript = record
                if reduceMotion {
                    loadState = .loaded
                } else {
                    withAnimation(.easeOut(duration: 0.22)) {
                        loadState = .loaded
                    }
                }
            } else {
                loadState = .missing
            }
        } catch {
            guard !Task.isCancelled, requested == tapeLoadKey else { return }
            loadState = .failed("Could not read the indexed transcript. Try again, or open Session Logs.")
        }
    }
}

// MARK: - Shared link control

struct ReceiptLinkButton: View {
    let title: String
    let systemImage: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }
}

// MARK: - Dashed divider (shared with the thermal slip rhythm)

struct ReceiptDashedDivider: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                path,
                with: .color(.primary.opacity(0.22)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

/// In-app first: `AppCommandRouter` already owns `receipts` / `sessions`.
/// Fall back to the URL scheme only if the router is not installed.
enum ReceiptDeepLink {
    @MainActor
    static func open(_ url: URL) {
        AppCommandRouter.shared.open(url)
    }
}

/// Shared harness ink for the register stack and the CHAT TAPE stamps.
enum ReceiptHarnessInk {
    static func color(for provider: AgentProvider) -> Color {
        switch provider {
        case .claudeCode:
            return Color(red: 0.85, green: 0.45, blue: 0.25)
        case .codex:
            return Color(red: 0.15, green: 0.68, blue: 0.55)
        case .cursor, .cursorAgent:
            return Color(red: 0.25, green: 0.55, blue: 0.95)
        case .factory:
            return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .xAI:
            return Color(red: 0.92, green: 0.32, blue: 0.32)
        case .muse:
            return Color(red: 0.02, green: 0.41, blue: 0.88)
        case .aider:
            return Color(red: 0.45, green: 0.75, blue: 0.35)
        case .geminiCLI:
            return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .goose:
            return Color(red: 0.15, green: 0.62, blue: 0.48)
        case .openClaude:
            return Color(red: 0.80, green: 0.40, blue: 0.28)
        case .openCode:
            return Color(red: 0.20, green: 0.72, blue: 0.78)
        case .hermes:
            return Color(red: 0.82, green: 0.62, blue: 0.22)
        case .piAgent:
            return Color(red: 0.48, green: 0.28, blue: 0.86)
        case .antigravity:
            return Color(red: 0.42, green: 0.38, blue: 0.98)
        case .primeAgent:
            return Color(red: 0.92, green: 0.55, blue: 0.18)
        case .junie:
            return Color(red: 0.28, green: 0.78, blue: 0.38)
        case .ollama:
            return Color(red: 0.35, green: 0.45, blue: 0.55)
        case .kimi:
            return Color(red: 0.72, green: 0.42, blue: 0.88)
        case .minimax:
            return Color(red: 0.95, green: 0.45, blue: 0.22)
        case .zai:
            return Color(red: 0.18, green: 0.72, blue: 0.62)
        case .openClaw:
            return Color(red: 0.78, green: 0.28, blue: 0.42)
        case .forgeDev:
            return Color(red: 0.55, green: 0.48, blue: 0.38)
        case .omp:
            return Color(red: 0.32, green: 0.58, blue: 0.72)
        case .copilot:
            return Color(red: 0.45, green: 0.72, blue: 0.95)
        case .cline:
            return Color(red: 0.95, green: 0.62, blue: 0.22)
        case .kiloCode:
            return Color(red: 0.22, green: 0.68, blue: 0.55)
        case .rooCode:
            return Color(red: 0.88, green: 0.38, blue: 0.55)
        case .augment:
            return Color(red: 0.38, green: 0.52, blue: 0.92)
        case .fx:
            return Color(red: 0.62, green: 0.72, blue: 0.28)
        case .warp:
            return Color(red: 0.12, green: 0.82, blue: 0.72)
        case .windsurf:
            return Color(red: 0.18, green: 0.62, blue: 0.82)
        case .devin:
            return Color(red: 0.22, green: 0.42, blue: 0.78)
        case .mimo:
            return Color(red: 0.95, green: 0.28, blue: 0.42)
        case .openAI:
            return Color(red: 0.10, green: 0.66, blue: 0.52)
        case .openBurnBar:
            return Color.orange
        case .deepSeek:
            return Color(red: 0.28, green: 0.42, blue: 0.88)
        }
    }
}

/// Caps the Chat tape so a tool-heavy session cannot instantiate every
/// parsed block into the register scroll view at once.
enum ReceiptTranscriptTape: Sendable {
    static let fullTapeBlockCap = 80

    static func spokenBlocks(_ blocks: [TranscriptBlock]) -> [TranscriptBlock] {
        let spoken = blocks.filter { $0.kind == .userMessage || $0.kind == .assistantMessage }
        if spoken.isEmpty { return Array(blocks.prefix(16)) }
        return spoken
    }

    static func fullTapeBlocks(_ blocks: [TranscriptBlock]) -> [TranscriptBlock] {
        let kept = blocks.filter { $0.kind != .separator }
        let source = kept.isEmpty ? Array(blocks.prefix(16)) : kept
        return Array(source.prefix(fullTapeBlockCap))
    }

    static func omittedFullTapeCount(_ blocks: [TranscriptBlock]) -> Int {
        let kept = blocks.filter { $0.kind != .separator }
        let source = kept.isEmpty ? Array(blocks.prefix(16)) : kept
        return max(0, source.count - fullTapeBlockCap)
    }
}
