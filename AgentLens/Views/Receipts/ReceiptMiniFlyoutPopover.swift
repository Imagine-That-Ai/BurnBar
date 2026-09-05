import SwiftUI
import OpenBurnBarCore

// MARK: - Receipt Mini Flyout View

/// A transient floating mini-flyout displayed directly beneath the OpenBurnBar status item
/// when an external CLI session completes.
public struct ReceiptMiniFlyoutView: View {
    public let receipt: ReceiptRecord
    public var onViewReceipt: () -> Void
    public var onDismiss: () -> Void

    @State private var progress: Double = 1.0
    @State private var hasCopied = false
    @Environment(\.colorScheme) private var colorScheme

    public init(
        receipt: ReceiptRecord,
        onViewReceipt: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.receipt = receipt
        self.onViewReceipt = onViewReceipt
        self.onDismiss = onDismiss
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.96)
            : Color(red: 0.98, green: 0.98, blue: 0.99).opacity(0.96)
    }

    private var headlineText: String {
        if let first = receipt.actualAccomplishments.first, !first.isEmpty {
            return first
        }
        if !receipt.promptSummary.isEmpty {
            return receipt.promptSummary
        }
        return "Session completed in \(receipt.projectName)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Icon + Harness + Dismiss
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "scroll.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14, weight: .bold))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(receipt.harness)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)

                        Text("•")
                            .foregroundStyle(.secondary)
                            .font(.caption2)

                        Text(receipt.projectName)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text("NEW RECEIPT PRINTED")
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss flyout")
            }

            // Accomplishment Headline
            Text(headlineText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Metrics Bar
            HStack(spacing: 8) {
                metricChip(icon: "dollarsign.circle.fill", text: receipt.formattedCost, color: .orange)
                metricChip(icon: "clock.fill", text: receipt.formattedDuration, color: .secondary)

                if receipt.cacheHitPercentage > 0 {
                    metricChip(icon: "arrow.triangle.2.circlepath", text: String(format: "%.0f%% cache", receipt.cacheHitPercentage), color: .green)
                }

                if let review = receipt.qualityReview {
                    HStack(spacing: 3) {
                        Text("GRADE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                        Text(review.grade)
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()
            }

            // Action Buttons
            HStack(spacing: 8) {
                Button(action: onViewReceipt) {
                    HStack(spacing: 5) {
                        Text("View Receipt")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    ReceiptExportService.copyMarkdownToClipboard(receipt: receipt)
                    hasCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        hasCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(hasCopied ? "Copied!" : "PR Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            // Subtle countdown bar
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.orange.opacity(0.4))
                    .frame(width: geo.size.width * progress, height: 2)
                    .clipShape(Capsule())
            }
            .frame(height: 2)
        }
        .padding(12)
        .frame(width: 330)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(cardBackground)
                .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.linear(duration: 8.0)) {
                progress = 0.0
            }
        }
    }

    private func metricChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.05))
        .foregroundStyle(color)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
