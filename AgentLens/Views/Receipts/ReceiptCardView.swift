import AppKit
import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Slip Inspector State

/// The slip inspector's local state, lifted out of `ReceiptDetailCardView` so the
/// rule about what survives a receipt switch is a value type a test can exercise
/// without mounting a view.
///
/// `ReceiptDetailCardView` is deliberately rendered *without* `.id(receipt.id)`:
/// one view instance sees successive receipts, and `receiptChanged(to:)` is what
/// keeps per-receipt state from leaking between slips. The lens is the one thing
/// that is not reset — it is a viewing mode the user chose, not a property of the
/// receipt, and snapping it back to Thermal on every click in the stack list is a
/// regression, not stale-state hygiene.
struct ReceiptInspectorState: Equatable {
    static let defaultCopiedAlertText = "Copied to Clipboard"

    var selectedLens: ReceiptLens
    var isStarred: Bool
    var showCopiedAlert: Bool
    var copiedAlertText: String

    init(receipt: ReceiptRecord, lens: ReceiptLens = .thermal) {
        self.selectedLens = lens
        self.isStarred = receipt.isStarred
        self.showCopiedAlert = false
        self.copiedAlertText = Self.defaultCopiedAlertText
    }

    /// Re-seed the per-receipt state for a newly selected receipt. `selectedLens`
    /// survives on purpose; see the type comment.
    mutating func receiptChanged(to receipt: ReceiptRecord) {
        isStarred = receipt.isStarred
        showCopiedAlert = false
        copiedAlertText = Self.defaultCopiedAlertText
    }
}

// MARK: - Receipt Detail Card View

struct ReceiptDetailCardView: View {
    let receipt: ReceiptRecord
    var overlay: ReceiptConversationOverlay?
    var dataStore: DataStore?
    var requestedLens: ReceiptLens?
    var lensRequestToken: UUID
    var onToggleStar: ((Bool) -> Void)?
    var onUpdateReview: ((ReceiptQualityReview) -> Void)?

    @State private var state: ReceiptInspectorState

    init(
        receipt: ReceiptRecord,
        overlay: ReceiptConversationOverlay? = nil,
        dataStore: DataStore? = nil,
        initialLens: ReceiptLens = .thermal,
        requestedLens: ReceiptLens? = nil,
        lensRequestToken: UUID = UUID(),
        onToggleStar: ((Bool) -> Void)? = nil,
        onUpdateReview: ((ReceiptQualityReview) -> Void)? = nil
    ) {
        self.receipt = receipt
        self.overlay = overlay
        self.dataStore = dataStore
        self.requestedLens = requestedLens
        self.lensRequestToken = lensRequestToken
        self._state = State(initialValue: ReceiptInspectorState(receipt: receipt, lens: requestedLens ?? initialLens))
        self.onToggleStar = onToggleStar
        self.onUpdateReview = onUpdateReview
    }

    private var chatSummary: String {
        ReceiptChatBridge.contentSummary(receipt: receipt, overlay: overlay)
    }

    var body: some View {
        VStack(spacing: 14) {
            // Top Controls: Lens Segmented Picker & Actions
            topToolbar

            if state.selectedLens != .transcript {
                chatSummaryBanner
            }

            // Lens Content with smooth transition
            ZStack {
                switch state.selectedLens {
                case .thermal:
                    ReceiptThermalSlipView(
                        receipt: receipt,
                        overlay: overlay,
                        onUpdateReview: onUpdateReview,
                        onToggleStar: { toggleStar() }
                    )
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                case .efficiency:
                    ReceiptEfficiencyLensView(receipt: receipt)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                case .audit:
                    ReceiptAuditLensView(receipt: receipt, overlay: overlay)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                case .transcript:
                    ReceiptTranscriptLensView(
                        receipt: receipt,
                        overlay: overlay,
                        dataStore: dataStore,
                        onCopied: { triggerCopiedToast($0) }
                    )
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.selectedLens)

            // Copied Toast Overlay if triggered
            if state.showCopiedAlert {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(state.copiedAlertText)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(.capsule)
                .shadow(radius: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .frame(maxWidth: 520)
        .onChange(of: receipt.id) { _, _ in
            state.receiptChanged(to: receipt)
        }
        .onChange(of: receipt.isStarred) { _, newStarred in
            state.isStarred = newStarred
        }
        .onChange(of: lensRequestToken) { _, _ in
            if let requestedLens {
                state.selectedLens = requestedLens
            }
        }
        .onAppear {
            if let requestedLens {
                state.selectedLens = requestedLens
            }
        }
    }

    // MARK: - Subviews

    private var topToolbar: some View {
        HStack(spacing: 8) {
            // Lens Picker
            Picker("Lens", selection: $state.selectedLens) {
                ForEach(ReceiptLens.allCases) { lens in
                    Text(lens.pickerTitle).tag(lens)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Star / Bookmark Button
            Button {
                state.isStarred.toggle()
                onToggleStar?(state.isStarred)
            } label: {
                Image(systemName: state.isStarred ? "star.fill" : "star")
                    .foregroundStyle(state.isStarred ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel(state.isStarred ? "Starred receipt" : "Unstarred receipt")

            // Share / Export Menu
            Menu {
                Button {
                    ReceiptExportService.copyReceiptImageToClipboard(
                        view: ReceiptThermalSlipView(receipt: receipt, overlay: overlay)
                    )
                    triggerCopiedToast("Thermal Slip PNG Copied")
                } label: {
                    Label("Copy PNG Image", systemImage: "photo")
                }

                Button {
                    ReceiptExportService.saveReceiptImageToFile(
                        view: ReceiptThermalSlipView(receipt: receipt, overlay: overlay),
                        suggestedFileName: "receipt-\(receipt.projectName)-\(receipt.shortSignature).png"
                    )
                } label: {
                    Label("Save PNG to File…", systemImage: "arrow.down.doc")
                }

                Divider()

                Button {
                    ReceiptExportService.copyMarkdownToClipboard(receipt: receipt, overlay: overlay)
                    triggerCopiedToast("Markdown Table Copied")
                } label: {
                    Label("Copy Markdown Table", systemImage: "doc.text")
                }

                Button {
                    ReceiptExportService.copyJSONToClipboard(receipt: receipt)
                    triggerCopiedToast("JSON Data Copied")
                } label: {
                    Label("Copy JSON", systemImage: "curlybraces")
                }

                Divider()

                Button {
                    ReceiptExportService.printReceipt(
                        view: ReceiptThermalSlipView(receipt: receipt, overlay: overlay)
                    )
                } label: {
                    Label("Print / Save as PDF…", systemImage: "printer")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
    }

    private var chatSummaryBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Chat")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if let count = overlay?.messageCount, count > 0 {
                    Text("\(count) turns")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(chatSummary.isEmpty ? "Open Chat for the transcript of this session." : chatSummary)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button {
                    state.selectedLens = .transcript
                } label: {
                    Label("Read transcript", systemImage: "text.bubble")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    if let url = ReceiptChatBridge.sessionURL(
                        conversationID: ReceiptChatBridge.conversationID(receipt: receipt, overlay: overlay)
                    ) {
                        ReceiptDeepLink.open(url)
                    }
                } label: {
                    Label("Open in Session Logs", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func toggleStar() {
        state.isStarred.toggle()
        onToggleStar?(state.isStarred)
    }

    private func triggerCopiedToast(_ message: String) {
        state.copiedAlertText = message
        withAnimation { state.showCopiedAlert = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { state.showCopiedAlert = false }
        }
    }
}
