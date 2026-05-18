import Foundation

/// Renders the monthly review artifact.
///
/// Longer-form than the weekly recap, with one chart-of-the-month
/// featured and a deeper trend narrative.
public struct MonthlyReviewRenderer: Sendable {

    public init() {}

    public func render(verdict: InsightVerdict) -> CadenceArtifact {
        var lines: [String] = []
        lines.append("Monthly Review — \(verdict.window.displayLabel)")
        lines.append(String(repeating: "═", count: 40))
        lines.append("")
        lines.append(verdict.headline)
        if let subhead = verdict.subhead {
            lines.append(subhead)
        }
        lines.append("")
        lines.append("TOP NUMBERS")
        for number in verdict.keyNumbers.prefix(4) {
            let delta = number.delta.map { formatDelta($0) } ?? ""
            lines.append("  • \(number.label): \(number.value)\(delta)")
        }
        lines.append("")
        lines.append("HIGHLIGHTS")
        for bullet in verdict.bullets.prefix(3) {
            lines.append("  • \(bullet.claim)")
        }
        if let rec = verdict.recommendation {
            lines.append("")
            lines.append("RECOMMENDATION")
            lines.append("  → \(rec.headline)")
            lines.append("    \(rec.rationale)")
            lines.append("    Impact: \(rec.expectedImpact)")
        }

        let body = lines.joined(separator: "\n")

        return CadenceArtifact(
            cadence: .monthly,
            verdict: verdict,
            payload: .email(
                subject: "Monthly AI Review — \(verdict.window.displayLabel)",
                htmlBody: htmlWrap(body, title: "Monthly Review")
            ),
            provenance: verdict.provenance
        )
    }

    private func formatDelta(_ delta: VerdictDelta) -> String {
        let sign = delta.value >= 0 ? "+" : ""
        let valueString: String
        switch delta.unit {
        case .usd: valueString = String(format: "%.2f", delta.value)
        case .percent, .ratio: valueString = String(format: "%.1f", delta.value)
        default: valueString = String(format: "%.0f", delta.value)
        }
        return " (\(sign)\(valueString)\(delta.unit.symbol))"
    }

    private func htmlWrap(_ body: String, title: String) -> String {
        let escapedBody = body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="UTF-8"><title>\(escapedTitle)</title></head>
        <body style="font-family: system-ui, sans-serif; max-width: 640px; margin: 32px auto; color: #1a1a1a; line-height: 1.6;">
        <h1 style="font-weight: 600;">\(escapedTitle)</h1>
        <p>\(escapedBody)</p>
        <hr style="border: none; border-top: 1px solid #ddd; margin: 24px 0;">
        <p style="font-size: 12px; color: #888;">OpenBurnBar · burnbar.ai</p>
        </body>
        </html>
        """
    }
}
