import Foundation

/// Renders the weekly recap artifact with the locked schema from plan §5.3.
///
/// ```
/// Week of {dateRange}
/// ─────────────────────────
/// NUMBERS
///   • Spend: ${this} ({delta} vs last week)
///   • Sessions: {n} ({delta})
///   • Cache hit: {pct}% ({delta})
///
/// WINS
///   • {one specific outcome with sessionIds}
///
/// SURPRISES
///   • {one anomaly or pattern the user wouldn't have noticed}
///
/// RISKS
///   • {quota / spend pace / cache decay / secret leak}
///
/// TRY NEXT WEEK
///   • {one accept-able recommendation}
/// ```
public struct WeeklyRecapRenderer: Sendable {

    public init() {}

    public func render(verdict: InsightVerdict, priorVerdict: InsightVerdict?) -> CadenceArtifact {
        var lines: [String] = []
        lines.append("Week of \(verdict.window.displayLabel)")
        lines.append(String(repeating: "─", count: 30))
        lines.append("")
        lines.append("NUMBERS")

        let spendRing = verdict.rings.first { $0.identity == .spend }
        let cacheRing = verdict.rings.first { $0.identity == .cache }
        let sessionsRing = verdict.rings.first { $0.identity == .sessions }

        if let spend = spendRing {
            let delta = formatDelta(spend.delta)
            lines.append(delta.isEmpty ? "  • Spend: \(spend.valueLabel)" : "  • Spend: \(spend.valueLabel) \(delta)")
        }
        if let cache = cacheRing {
            let delta = formatDelta(cache.delta)
            lines.append(delta.isEmpty ? "  • Cache hit: \(cache.valueLabel)" : "  • Cache hit: \(cache.valueLabel) \(delta)")
        }
        if let sessions = sessionsRing {
            let delta = formatDelta(sessions.delta)
            lines.append(delta.isEmpty ? "  • Sessions: \(sessions.valueLabel)" : "  • Sessions: \(sessions.valueLabel) \(delta)")
        }

        lines.append("")
        lines.append("WINS")
        let win = verdict.bullets.first { $0.type == .reflectiveFact || $0.type == .achievement }
            ?? verdict.bullets.first
        if let win = win {
            lines.append("  • \(win.claim)")
        } else {
            lines.append("  • Nothing flagged this week.")
        }

        lines.append("")
        lines.append("SURPRISES")
        let surprise = verdict.bullets.first { $0.type == .anomaly || $0.type == .pattern }
        if let surprise = surprise {
            lines.append("  • \(surprise.claim)")
        } else {
            lines.append("  • No surprises this week.")
        }

        lines.append("")
        lines.append("RISKS")
        let risk = verdict.bullets.first { $0.type == .risk }?.claim
            ?? verdict.anomaly.map { "\($0.label): \($0.detail)" }
        if let risk = risk {
            lines.append("  • \(risk)")
        } else {
            lines.append("  • No risks flagged.")
        }

        lines.append("")
        lines.append("TRY NEXT WEEK")
        if let rec = verdict.recommendation {
            lines.append("  • \(rec.headline) — \(rec.expectedImpact)")
        } else if let recBullet = verdict.bullets.first(where: { $0.type == .recommendation }) {
            lines.append("  • \(recBullet.claim)")
        } else {
            lines.append("  • Keep logging — insights get sharper with more data.")
        }

        let body = lines.joined(separator: "\n")

        return CadenceArtifact(
            cadence: .weekly,
            verdict: verdict,
            payload: .email(
                subject: "Your week in AI — \(verdict.window.displayLabel)",
                htmlBody: htmlWrap(body, title: "Weekly Recap")
            ),
            provenance: verdict.provenance
        )
    }

    private func formatDelta(_ delta: VerdictDelta?) -> String {
        guard let delta = delta else { return "" }
        let sign = delta.value >= 0 ? "+" : ""
        let valueString: String
        switch delta.unit {
        case .usd: valueString = String(format: "%.2f", delta.value)
        case .percent, .ratio: valueString = String(format: "%.1f", delta.value)
        default: valueString = String(format: "%.0f", delta.value)
        }
        return "(\(sign)\(valueString)\(delta.unit.symbol) vs \(delta.baseline))"
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
        <body style="font-family: system-ui, sans-serif; max-width: 600px; margin: 24px auto; color: #1a1a1a;">
        <h2>\(escapedTitle)</h2>
        <p style="line-height: 1.6;">\(escapedBody)</p>
        <hr>
        <p style="font-size: 12px; color: #888;">OpenBurnBar · burnbar.ai</p>
        </body>
        </html>
        """
    }
}
