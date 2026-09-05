import AppKit
import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Barcode View (Thermal Receipt Styling)

struct ReceiptBarcodeView: View {
    let signature: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(signature.prefix(36).enumerated()), id: \.offset) { index, char in
                let val = Int(char.asciiValue ?? 0)
                let barWidth: CGFloat = (val % 3 == 0) ? 3 : ((val % 2 == 0) ? 2 : 1)
                let isSpace = (val % 5 == 0 && index % 4 == 0)

                if isSpace {
                    Color.clear.frame(width: 2)
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: barWidth)
                }
            }
        }
        .frame(height: 28)
    }
}

// MARK: - Thermal Slip View

struct ReceiptThermalSlipView: View {
    let receipt: ReceiptRecord
    var onUpdateReview: ((ReceiptQualityReview) -> Void)?
    var onToggleStar: (() -> Void)?

    @State private var isGrading = false
    @State private var hasCopied = false
    @State private var localReview: ReceiptQualityReview?
    @Environment(\.colorScheme) private var colorScheme

    init(
        receipt: ReceiptRecord,
        onUpdateReview: ((ReceiptQualityReview) -> Void)? = nil,
        onToggleStar: (() -> Void)? = nil
    ) {
        self.receipt = receipt
        self.onUpdateReview = onUpdateReview
        self.onToggleStar = onToggleStar
        self._localReview = State(initialValue: receipt.qualityReview)
    }

    private var effectiveReview: ReceiptQualityReview? {
        localReview ?? receipt.qualityReview
    }

    private var paperBackground: Color {
        if colorScheme == .dark {
            return Color(red: 0.12, green: 0.12, blue: 0.13)
        } else {
            return Color(red: 0.98, green: 0.98, blue: 0.97)
        }
    }

    private var paperBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Serrated Tooth Edge
            SerratedEdgeShape(toothCount: 22, toothHeight: 4, isTop: true)
                .fill(paperBackground)
                .frame(height: 4)

            // Main Receipt Paper Body
            VStack(spacing: 12) {
                // Header (Harness, Provider, Project)
                headerSection

                dashedDivider

                // Context & Task summary
                if !receipt.promptSummary.isEmpty {
                    taskSummarySection
                    dashedDivider
                }

                // Git & Repository Deliverables (if any)
                if receipt.gitStats != nil || receipt.gitBranch != nil || receipt.gitCommit != nil {
                    gitDeliverablesSection
                    dashedDivider
                }

                // What was ACTUALLY accomplished
                if !receipt.actualAccomplishments.isEmpty {
                    accomplishmentsSection
                    dashedDivider
                }

                // Achievements Badges
                if !receipt.achievements.isEmpty {
                    achievementsSection
                    dashedDivider
                }

                // Quality Review & Rubric
                qualityReviewSection

                dashedDivider

                // Itemized Token Economics
                itemizedLinesSection

                dashedDivider

                // Totals & Cache Discount
                totalsSection

                dashedDivider

                // Actions Bar (Copy Markdown, Star)
                actionsSection

                dashedDivider

                // Footer with Barcode and Signature
                footerSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(paperBackground)

            // Bottom Serrated Tooth Edge
            SerratedEdgeShape(toothCount: 22, toothHeight: 4, isTop: false)
                .fill(paperBackground)
                .frame(height: 4)
        }
        .frame(maxWidth: 380)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(paperBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.08), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thermal receipt for \(receipt.projectName), total cost \(receipt.formattedCost)")
        .onChange(of: receipt.id) { _, _ in
            localReview = receipt.qualityReview
            isGrading = false
            hasCopied = false
        }
        .onChange(of: receipt.qualityReview) { _, newReview in
            localReview = newReview
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("OPENBURNBAR RECEIPT")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(1.5)
            }

            Text(receipt.timestamp.formatted(date: .abbreviated, time: .standard))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            // Harness & Project Badges
            HStack(spacing: 6) {
                Text(receipt.harness.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14))
                    .foregroundStyle(.orange)
                    .clipShape(.rect(cornerRadius: 3))

                Text("•")
                    .foregroundStyle(.secondary)

                Text(receipt.projectName.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 3))
            }
            .padding(.top, 2)

            Text("MODEL: \(receipt.modelName)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var taskSummarySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("PROMPT / GOAL:")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(receipt.promptSummary)
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(3)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .clipShape(.rect(cornerRadius: 4))
    }

    private var gitDeliverablesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("GIT EVIDENCE:")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if let branch = receipt.gitBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(branch)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if let git = receipt.gitStats {
                Text(git.summary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            } else if let commit = receipt.gitCommit {
                Text("Commit: \(commit.prefix(8))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.primary.opacity(0.025))
        .clipShape(.rect(cornerRadius: 4))
    }

    private var accomplishmentsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("ACTUALLY ACCOMPLISHED:")
                    .font(.system(size: 8.5, weight: .black, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.green)
            }

            ForEach(receipt.actualAccomplishments, id: \.self) { item in
                HStack(alignment: .top, spacing: 5) {
                    Text("☑")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.green.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: 4))
    }

    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ACHIEVEMENTS EARNED:")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            ReceiptFlowLayout(spacing: 5) {
                ForEach(receipt.achievements) { badge in
                    HStack(spacing: 4) {
                        Image(systemName: badge.icon)
                            .font(.system(size: 9))
                        Text(badge.title)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .foregroundStyle(.orange)
                    .clipShape(.rect(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 0.8)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var qualityReviewSection: some View {
        VStack(spacing: 8) {
            if let review = effectiveReview {
                VStack(alignment: .leading, spacing: 6) {
                    // Header Stamp
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("QUALITY AUDIT")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundStyle(.blue)
                            Text("SCORE: \(Int(review.score))/100")
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // Rubber Stamp Badge
                        Text(review.grade)
                            .font(.system(size: 16, weight: .black, design: .monospaced))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.blue, lineWidth: 1.5)
                            )
                            .rotationEffect(.degrees(-6))
                    }

                    // Rubric sub-scores
                    HStack(spacing: 8) {
                        subscorePill(title: "GOAL", score: review.goalScore)
                        subscorePill(title: "RIGOR", score: review.rigorScore)
                        subscorePill(title: "EFFICIENCY", score: review.efficiencyScore)
                    }

                    // Wins
                    ForEach(review.wins, id: \.self) { win in
                        HStack(alignment: .top, spacing: 4) {
                            Text("✓")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.blue)
                            Text(win)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }

                    // Critiques
                    ForEach(review.critiques, id: \.self) { critique in
                        HStack(alignment: .top, spacing: 4) {
                            Text("⚠︎")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(critique)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color.blue.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
                .clipShape(.rect(cornerRadius: 4))
            } else {
                Button {
                    gradeSessionOnDemand()
                } label: {
                    HStack(spacing: 5) {
                        if isGrading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                        }
                        Text(isGrading ? "Auditing Session…" : "⚡️ Grade this Session (Quality Review)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(.rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(isGrading)
            }
        }
    }

    private func subscorePill(title: String, score: Double) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(Int(score))")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 3))
    }

    private func gradeSessionOnDemand() {
        isGrading = true
        Task { @MainActor in
            let auditor = ReceiptQualityAuditor()
            let review = await auditor.audit(receipt: receipt)
            self.localReview = review
            self.isGrading = false
            ReceiptAudioPlayer.playQualityAuditStampSound()
            onUpdateReview?(review)
        }
    }

    private var itemizedLinesSection: some View {
        VStack(spacing: 6) {
            itemRow(title: "INPUT TOKENS", value: "\(receipt.inputTokens)")
            itemRow(title: "OUTPUT TOKENS", value: "\(receipt.outputTokens)")

            if receipt.cacheReadTokens > 0 {
                HStack {
                    Text("CACHE READ (DISCOUNT)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.green)
                    Spacer()
                    Text("-\(receipt.formattedSavings)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                itemRow(title: "  ↳ Cached Tokens", value: "\(receipt.cacheReadTokens)", isSecondary: true)
            }

            if receipt.cacheWriteTokens > 0 {
                itemRow(title: "CACHE CREATION", value: "\(receipt.cacheWriteTokens)", isSecondary: true)
            }

            if receipt.durationSeconds > 0 {
                itemRow(title: "DURATION / SPEED", value: "\(receipt.formattedDuration) • \(String(format: "%.0f tok/s", receipt.tokensPerSecond))", isSecondary: true)
            }
        }
    }

    private func itemRow(title: String, value: String, isSecondary: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: isSecondary ? 9.5 : 10.5, design: .monospaced))
                .foregroundStyle(isSecondary ? .secondary : .primary)
            Spacer()
            Text(value)
                .font(.system(size: isSecondary ? 9.5 : 10.5, weight: isSecondary ? .regular : .medium, design: .monospaced))
                .foregroundStyle(isSecondary ? .secondary : .primary)
        }
    }

    private var totalsSection: some View {
        VStack(spacing: 5) {
            HStack {
                Text("TOTAL TOKENS")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Text(receipt.formattedTokens)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }

            if receipt.estimatedCacheSavingsUSD > 0 {
                HStack {
                    Text("EST. CACHE SAVINGS")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                    Spacer()
                    Text("-\(receipt.formattedSavings)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }

            HStack {
                Text("TOTAL BURN")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                Spacer()
                Text(receipt.formattedCost)
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.top, 2)
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 8) {
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
                    Text(hasCopied ? "Copied Receipt!" : "Copy for PR (Markdown)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))
                .foregroundStyle(.primary)
                .clipShape(.rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            if let onToggleStar {
                Button(action: onToggleStar) {
                    Image(systemName: receipt.isStarred ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(receipt.isStarred ? .yellow : .secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(.rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            ReceiptBarcodeView(signature: receipt.contentSignature)

            HStack(spacing: 4) {
                Text("SIG:")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(receipt.shortSignature)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("✦ THANK YOU FOR BUILDING WITH AI ✦")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.8))
                .padding(.top, 2)
        }
    }

    private var dashedDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                Line()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.primary.opacity(0.2))
            )
            .padding(.vertical, 2)
    }
}

// MARK: - FlowLayout Helper for Badges

private struct ReceiptFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
        height = currentY + rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
    }
}

// MARK: - Simple Line Helper for Dashed Divider

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

// MARK: - Serrated Edge Shape

struct SerratedEdgeShape: Shape {
    var toothCount: Int = 22
    var toothHeight: CGFloat = 4
    var isTop: Bool = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(1, toothCount)
        let toothWidth = rect.width / CGFloat(count)

        if isTop {
            path.move(to: CGPoint(x: 0, y: rect.maxY))
            for i in 0..<count {
                let xStart = CGFloat(i) * toothWidth
                let xMid = xStart + (toothWidth / 2.0)
                let xEnd = xStart + toothWidth
                path.addLine(to: CGPoint(x: xMid, y: rect.minY))
                path.addLine(to: CGPoint(x: xEnd, y: rect.maxY))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: 0, y: rect.minY))
            for i in 0..<count {
                let xStart = CGFloat(i) * toothWidth
                let xMid = xStart + (toothWidth / 2.0)
                let xEnd = xStart + toothWidth
                path.addLine(to: CGPoint(x: xMid, y: rect.maxY))
                path.addLine(to: CGPoint(x: xEnd, y: rect.minY))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }

        return path
    }
}
