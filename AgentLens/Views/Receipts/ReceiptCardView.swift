import AppKit
import Foundation
import OpenBurnBarCore
import SwiftUI

// MARK: - Receipt Detail Card View

struct ReceiptDetailCardView: View {
    let receipt: ReceiptRecord
    var onToggleStar: ((Bool) -> Void)? = nil
    var onUpdateReview: ((ReceiptQualityReview) -> Void)? = nil

    @State private var selectedLens: ReceiptLens = .thermal
    @State private var isStarred: Bool
    @State private var showCopiedAlert = false
    @State private var copiedAlertText = "Copied to Clipboard"

    init(
        receipt: ReceiptRecord,
        initialLens: ReceiptLens = .thermal,
        onToggleStar: ((Bool) -> Void)? = nil,
        onUpdateReview: ((ReceiptQualityReview) -> Void)? = nil
    ) {
        self.receipt = receipt
        self._selectedLens = State(initialValue: initialLens)
        self._isStarred = State(initialValue: receipt.isStarred)
        self.onToggleStar = onToggleStar
        self.onUpdateReview = onUpdateReview
    }

    var body: some View {
        VStack(spacing: 14) {
            // Top Controls: Lens Segmented Picker & Actions
            topToolbar

            // Lens Content with smooth transition
            ZStack {
                switch selectedLens {
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
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedLens)

            // Copied Toast Overlay if triggered
            if showCopiedAlert {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(copiedAlertText)
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
    }

    // MARK: - Subviews

    private var topToolbar: some View {
        HStack(spacing: 8) {
            // Lens Picker
            Picker("Lens", selection: $selectedLens) {
                ForEach(ReceiptLens.allCases) { lens in
                    Label(lens.title, systemImage: lens.iconName)
                        .tag(lens)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Star / Bookmark Button
            Button {
                isStarred.toggle()
                onToggleStar?(isStarred)
            } label: {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .foregroundStyle(isStarred ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel(isStarred ? "Starred receipt" : "Unstarred receipt")

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
        isStarred.toggle()
        onToggleStar?(isStarred)
    }

    private func triggerCopiedToast(_ message: String) {
        copiedAlertText = message
        withAnimation { showCopiedAlert = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { showCopiedAlert = false }
        }
    }
}
