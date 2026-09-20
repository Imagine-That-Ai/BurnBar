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
    var onToggleStar: ((Bool) -> Void)?
    var onUpdateReview: ((ReceiptQualityReview) -> Void)?

    @State private var state: ReceiptInspectorState

    init(
        receipt: ReceiptRecord,
        initialLens: ReceiptLens = .thermal,
        onToggleStar: ((Bool) -> Void)? = nil,
        onUpdateReview: ((ReceiptQualityReview) -> Void)? = nil
    ) {
        self.receipt = receipt
        self._state = State(initialValue: ReceiptInspectorState(receipt: receipt, lens: initialLens))
        self.onToggleStar = onToggleStar
        self.onUpdateReview = onUpdateReview
    }

    var body: some View {
        VStack(spacing: 14) {
            // Top Controls: Lens Segmented Picker & Actions
            topToolbar

            // Lens Content with smooth transition
            ZStack {
                switch state.selectedLens {
                case .thermal:
                    ReceiptThermalSlipView(
                        receipt: receipt,
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
                    ReceiptAuditLensView(receipt: receipt)
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
        .frame(maxWidth: 400)
        .onChange(of: receipt.id) { _, _ in
            state.receiptChanged(to: receipt)
        }
        .onChange(of: receipt.isStarred) { _, newStarred in
            state.isStarred = newStarred
        }
    }

    // MARK: - Subviews

    private var topToolbar: some View {
        HStack(spacing: 8) {
            // Lens Picker
            Picker("Lens", selection: $state.selectedLens) {
                ForEach(ReceiptLens.allCases) { lens in
                    Label(lens.title, systemImage: lens.iconName)
                        .tag(lens)
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
                        view: ReceiptThermalSlipView(receipt: receipt)
                    )
                    triggerCopiedToast("Thermal Slip PNG Copied")
                } label: {
                    Label("Copy PNG Image", systemImage: "photo")
                }

                Button {
                    ReceiptExportService.saveReceiptImageToFile(
                        view: ReceiptThermalSlipView(receipt: receipt),
                        suggestedFileName: "receipt-\(receipt.projectName)-\(receipt.shortSignature).png"
                    )
                } label: {
                    Label("Save PNG to File…", systemImage: "arrow.down.doc")
                }

                Divider()

                Button {
                    ReceiptExportService.copyMarkdownToClipboard(receipt: receipt)
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
                        view: ReceiptThermalSlipView(receipt: receipt)
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
