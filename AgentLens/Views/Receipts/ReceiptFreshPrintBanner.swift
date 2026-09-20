import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Fresh Print Banner / Toast

struct ReceiptFreshPrintBanner: View {
    let receipt: ReceiptRecord
    var onOpenReceipt: () -> Void
    var onDismiss: () -> Void

    @State private var appeared = false
    @Environment(\.colorScheme) private var colorScheme

    init(
        receipt: ReceiptRecord,
        onOpenReceipt: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.receipt = receipt
        self.onOpenReceipt = onOpenReceipt
        self.onDismiss = onDismiss
    }

    var body: some View {
        Button(action: onOpenReceipt) {
            HStack(spacing: 10) {
                // Receipt icon with pulse
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 30, height: 30)

                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.orange)
                }

                // Summary text
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(receipt.formattedCost)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)

                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(receipt.provider.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if receipt.cacheHitPercentage > 50 {
                            Text(String(format: "%.0f%% cached", receipt.cacheHitPercentage))
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(.capsule)
                        }
                    }

                    Text("\(receipt.projectName) • \(receipt.formattedTokens) tokens • \(receipt.formattedDuration)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Dismiss button
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 380)
        .offset(y: appeared ? 0 : -20)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fresh receipt for \(receipt.projectName), cost \(receipt.formattedCost)")
    }
}
