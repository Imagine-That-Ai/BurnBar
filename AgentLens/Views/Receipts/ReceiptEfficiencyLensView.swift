import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Efficiency Lens View

struct ReceiptEfficiencyLensView: View {
    let receipt: ReceiptRecord
    @Environment(\.colorScheme) private var colorScheme

    init(receipt: ReceiptRecord) {
        self.receipt = receipt
    }

    private var promptRatio: String {
        guard receipt.inputTokens > 0 else { return "—" }
        let ratio = Double(receipt.outputTokens) / Double(receipt.inputTokens)
        return String(format: "1 : %.1f", ratio)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Top Cache Efficiency Hero Card
            cacheHeroCard

            // Speed & Throughput Row
            HStack(spacing: 12) {
                metricCard(
                    title: "Throughput",
                    value: String(format: "%.1f", receipt.tokensPerSecond),
                    unit: "tok/s",
                    icon: "bolt.fill",
                    tint: .orange
                )

                metricCard(
                    title: "Duration",
                    value: receipt.formattedDuration,
                    unit: "elapsed",
                    icon: "timer",
                    tint: .blue
                )
            }

            // Token Breakdown & Prompt Ratio Row
            HStack(spacing: 12) {
                metricCard(
                    title: "Prompt Ratio",
                    value: promptRatio,
                    unit: "in:out",
                    icon: "arrow.left.arrow.right",
                    tint: .purple
                )

                metricCard(
                    title: "Net Savings",
                    value: receipt.formattedSavings,
                    unit: "cached",
                    icon: "arrow.down.circle.fill",
                    tint: .green
                )
            }

            // Detailed Economics Table
            VStack(alignment: .leading, spacing: 8) {
                Text("Token Composition")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                tokenBar

                HStack {
                    legendItem(title: "Input", value: "\(receipt.inputTokens)", color: .blue)
                    Spacer()
                    legendItem(title: "Output", value: "\(receipt.outputTokens)", color: .purple)
                    Spacer()
                    legendItem(title: "Cached", value: "\(receipt.cacheReadTokens)", color: .green)
                }
                .padding(.top, 4)
            }
            .padding(14)
            .background(Color.primary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 10))
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Efficiency metrics for \(receipt.projectName), cache hit \(String(format: "%.1f%%", receipt.cacheHitPercentage))")
    }

    // MARK: - Subviews

    private var cacheHeroCard: some View {
        HStack(spacing: 16) {
            // Circular progress gauge
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 8)
                    .frame(width: 64, height: 64)

                Circle()
                    .trim(from: 0, to: CGFloat(min(1.0, max(0.0, receipt.cacheHitPercentage / 100.0))))
                    .stroke(
                        LinearGradient(
                            colors: [.green, .mint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 64, height: 64)

                Text(String(format: "%.0f%%", receipt.cacheHitPercentage))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: receipt.cacheHitPercentage > 70 ? "leaf.fill" : "bolt.shield")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(receipt.cacheHitPercentage > 70 ? "High Cache Hit" : "Standard Cache")
                        .font(.subheadline)
                        .fontWeight(.bold)
                }

                Text("Prompt caching reduced input cost by **\(receipt.formattedSavings)** on this run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(colorScheme == .dark ? 0.12 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func metricCard(title: String, value: String, unit: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var tokenBar: some View {
        GeometryReader { proxy in
            let total = max(1, receipt.totalTokens)
            let inWidth = CGFloat(receipt.inputTokens) / CGFloat(total) * proxy.size.width
            let outWidth = CGFloat(receipt.outputTokens) / CGFloat(total) * proxy.size.width
            let cachedWidth = CGFloat(receipt.cacheReadTokens + receipt.cacheWriteTokens) / CGFloat(total) * proxy.size.width

            HStack(spacing: 2) {
                Rectangle().fill(Color.blue).frame(width: max(2, inWidth))
                Rectangle().fill(Color.purple).frame(width: max(2, outWidth))
                Rectangle().fill(Color.green).frame(width: max(2, cachedWidth))
            }
            .clipShape(.rect(cornerRadius: 3))
        }
        .frame(height: 8)
    }

    private func legendItem(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title): \(value)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
