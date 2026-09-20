import AppKit
import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Receipt Export Service

@MainActor
enum ReceiptExportService {

    // MARK: - Markdown Table Export

    static func makeMarkdown(for receipt: ReceiptRecord) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateStr = dateFormatter.string(from: receipt.timestamp)

        var md = """
        ### 🧾 OpenBurnBar Receipt: `\(receipt.projectName)`
        **Harness / Provider:** \(receipt.harness) (\(receipt.provider.displayName))  
        **Model:** `\(receipt.modelName)`  
        **Session:** `\(receipt.sessionId)`  
        **Timestamp:** \(dateStr) (\(receipt.formattedDuration))  
        **Audit Signature:** `\(receipt.contentSignature)`  

        | Item | Quantity / Metric | Cost / Value |
        | :--- | :--- | :--- |
        | **Input Tokens** | \(receipt.inputTokens) | — |
        | **Output Tokens** | \(receipt.outputTokens) | — |
        | **Cache Read Tokens** | \(receipt.cacheReadTokens) | *(Saved \(receipt.formattedSavings))* |
        | **Cache Write Tokens** | \(receipt.cacheWriteTokens) | — |
        | **Cache Hit Ratio** | \(String(format: "%.1f%%", receipt.cacheHitPercentage)) | — |
        | **Throughput** | \(String(format: "%.1f tok/s", receipt.tokensPerSecond)) | — |
        | **TOTAL SPEND** | **\(receipt.formattedTokens) tokens** | **\(receipt.formattedCost)** |

        """

        if let gitStats = receipt.gitStats {
            md += "\n**Git Deliverables:** \(gitStats.summary)\n"
        }

        if let branch = receipt.gitBranch {
            md += "**Git Branch:** `\(branch)`"
            if let commit = receipt.gitCommit {
                md += " @ `\(commit.prefix(7))`"
            }
            md += "\n"
        }

        if !receipt.actualAccomplishments.isEmpty {
            md += "\n#### ✅ Actually Accomplished:\n"
            for acc in receipt.actualAccomplishments {
                md += "- \(acc)\n"
            }
        }

        if let review = receipt.qualityReview {
            md += "\n#### 🏆 Quality Review: **Grade \(review.grade)** (\(String(format: "%.0f", review.score))/100)\n"
            md += "- **Goal Completion:** \(String(format: "%.0f%%", review.goalScore))\n"
            md += "- **Code & Test Rigor:** \(String(format: "%.0f%%", review.rigorScore))\n"
            md += "- **Token & Tool Efficiency:** \(String(format: "%.0f%%", review.efficiencyScore))\n"
            if !review.wins.isEmpty {
                md += "**Highlights:** " + review.wins.joined(separator: "; ") + "\n"
            }
            if !review.critiques.isEmpty {
                md += "**Notes:** " + review.critiques.joined(separator: "; ") + "\n"
            }
        }

        if !receipt.achievements.isEmpty {
            md += "\n**Badges Earned:** " + receipt.achievements.map { "\($0.title) (\($0.detail))" }.joined(separator: " • ") + "\n"
        }

        if !receipt.filesTouched.isEmpty {
            md += "\n**Files Touched (\(receipt.filesTouched.count)):**\n"
            for file in receipt.filesTouched.prefix(10) {
                md += "- `\(file)`\n"
            }
            if receipt.filesTouched.count > 10 {
                md += "- *...and \(receipt.filesTouched.count - 10) more*\n"
            }
        }

        return md
    }

    // MARK: - Batch Markdown Report

    static func makeBatchMarkdown(for receipts: [ReceiptRecord], summary: ReceiptAggregateSummary) -> String {
        var md = """
        # 🧾 OpenBurnBar Receipt Batch Report
        **Generated:** \(Date().formatted(date: .abbreviated, time: .shortened))  
        **Total Runs:** \(summary.count)  
        **Total Spend:** \(summary.formattedCost)  
        **Total Tokens:** \(summary.formattedTokens)  
        **Net Cache Savings:** \(summary.formattedSavings)  

        ---

        | Timestamp | Project | Provider / Model | Tokens | Cache % | Cost |
        | :--- | :--- | :--- | :--- | :--- | :--- |
        """

        for r in receipts {
            let timeStr = r.timestamp.formatted(date: .numeric, time: .shortened)
            md += "\n| \(timeStr) | `\(r.projectName)` | \(r.provider.displayName) (`\(r.modelName)`) | \(r.formattedTokens) | \(String(format: "%.0f%%", r.cacheHitPercentage)) | **\(r.formattedCost)** |"
        }

        return md
    }

    // MARK: - JSON Export

    static func makeJSON(for receipt: ReceiptRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(receipt),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return jsonStr
    }

    // MARK: - Clipboard Copy Helpers

    static func copyMarkdownToClipboard(receipt: ReceiptRecord) {
        let md = makeMarkdown(for: receipt)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(md, forType: .string)
    }

    static func copyJSONToClipboard(receipt: ReceiptRecord) {
        let json = makeJSON(for: receipt)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)
    }

    // MARK: - Image Rendering & PNG Export

    static func renderReceiptImage<Content: View>(view: Content) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.isOpaque = false
        return renderer.nsImage
    }

    static func copyReceiptImageToClipboard<Content: View>(view: Content) {
        guard let image = renderReceiptImage(view: view) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func saveReceiptImageToFile<Content: View>(view: Content, suggestedFileName: String = "receipt.png") {
        guard let image = renderReceiptImage(view: view),
              let tiffData = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = suggestedFileName
        savePanel.canCreateDirectories = true

        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                try? pngData.write(to: url)
            }
        }
    }

    // MARK: - Native Print Operation

    static func printReceipt<Content: View>(view: Content) {
        let hostingView = NSHostingView(rootView: view.padding(24))
        hostingView.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false

        let printOperation = NSPrintOperation(view: hostingView, printInfo: printInfo)
        printOperation.showsPrintPanel = true
        printOperation.run()
    }
}
