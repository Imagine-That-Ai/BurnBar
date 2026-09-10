import AppKit
import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Receipt Register Tape Header

struct ReceiptRegisterTapeHeader: View {
    let summary: ReceiptAggregateSummary
    let receipts: [ReceiptRecord]
    var onClearFilters: (() -> Void)?
    var hasActiveFilters: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var showCopiedAlert = false

    init(
        summary: ReceiptAggregateSummary,
        receipts: [ReceiptRecord],
        hasActiveFilters: Bool = false,
        onClearFilters: (() -> Void)? = nil
    ) {
        self.summary = summary
        self.receipts = receipts
        self.hasActiveFilters = hasActiveFilters
        self.onClearFilters = onClearFilters
    }

    private var tapeBackground: Color {
        if colorScheme == .dark {
            return Color(red: 0.14, green: 0.14, blue: 0.16)
        } else {
            return Color(red: 0.95, green: 0.95, blue: 0.93)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Register Icon & Count
                HStack(spacing: 6) {
                    Image(systemName: "banknote.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text("\(summary.count)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text(summary.count == 1 ? "Receipt" : "Receipts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 16)

                // Total Spend
                statItem(
                    label: "Total Burn",
                    value: summary.formattedCost,
                    color: .primary
                )

                Divider().frame(height: 16)

                // Total Tokens
                statItem(
                    label: "Volume",
                    value: "\(summary.formattedTokens) tok",
                    color: .secondary
                )

                if summary.totalCacheSavingsUSD > 0 {
                    Divider().frame(height: 16)

                    // Cache Savings
                    statItem(
                        label: "Cache Saved",
                        value: "+\(summary.formattedSavings)",
                        color: .green
                    )
                }

                Spacer()

                // Batch Actions Menu
                Menu {
                    Button {
                        let batchMd = ReceiptExportService.makeBatchMarkdown(
                            for: receipts,
                            summary: summary
                        )
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(batchMd, forType: .string)
                        triggerToast()
                    } label: {
                        Label("Copy Batch Markdown Table", systemImage: "doc.on.clipboard")
                    }

                    if hasActiveFilters {
                        Divider()
                        Button(role: .destructive) {
                            onClearFilters?()
                        } label: {
                            Label("Reset Active Filters", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(tapeBackground)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.primary.opacity(0.08)),
                alignment: .bottom
            )

            // Copied banner notification if triggered
            if showCopiedAlert {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                    Text("Batch Markdown Report Copied to Clipboard")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func statItem(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func triggerToast() {
        withAnimation { showCopiedAlert = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { showCopiedAlert = false }
        }
    }
}
