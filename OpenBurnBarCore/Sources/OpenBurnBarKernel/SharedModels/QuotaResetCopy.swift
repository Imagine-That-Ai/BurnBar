import Foundation

public enum QuotaResetCopy {
    public static func caption(
        kind: QuotaResetKind,
        providerToken: String,
        providerDisplayName: String,
        windowClass: QuotaResetWindowClass,
        accountLabel: String?,
        surpriseCountLastDay: Int,
        lastHeadline: String?,
        seed: String
    ) -> QuotaResetCaption {
        let isCodex = providerToken == "codex" || providerToken == "openai"
        let windowWord = windowLabel(windowClass)
        let name = providerDisplayName

        let options: [QuotaResetCaption]
        switch kind {
        case .scheduled:
            options = [
                QuotaResetCaption(
                    eyebrow: "\(name.uppercased()) · \(windowWord.uppercased())",
                    headline: "\(name)’s \(windowWord) window rolled. Fresh headroom.",
                    mentionsTibo: false
                ),
                QuotaResetCaption(
                    eyebrow: "SCHEDULED RESET · \(name.uppercased())",
                    headline: "The \(windowWord) clock struck. \(name) is full again.",
                    mentionsTibo: false
                ),
                QuotaResetCaption(
                    eyebrow: "WINDOW ROLL · \(name.uppercased())",
                    headline: "\(name) just started a new \(windowWord).",
                    mentionsTibo: false
                ),
                QuotaResetCaption(
                    eyebrow: "EMBER REKINDLED · \(name.uppercased())",
                    headline: "Ash cleared. \(name) has a clean \(windowWord) bar.",
                    mentionsTibo: false
                )
            ]
        case .surprise:
            if isCodex && surpriseCountLastDay >= 1 {
                options = [
                    QuotaResetCaption(
                        eyebrow: "TIBO · AGAIN",
                        headline: "That’s cute. How about twice?",
                        mentionsTibo: true
                    )
                ]
            } else if isCodex {
                options = [
                    QuotaResetCaption(
                        eyebrow: "SURPRISE RESET · CODEX",
                        headline: "Tibo hit the button. Codex is full again.",
                        mentionsTibo: true
                    ),
                    QuotaResetCaption(
                        eyebrow: "UNEXPECTED REFILL · CODEX",
                        headline: "Codex snapped back mid-window.",
                        mentionsTibo: false
                    ),
                    QuotaResetCaption(
                        eyebrow: "THE BUTTON · CODEX",
                        headline: "Someone slammed reset. Go /fast.",
                        mentionsTibo: false
                    )
                ]
            } else {
                options = [
                    QuotaResetCaption(
                        eyebrow: "SURPRISE RESET · \(name.uppercased())",
                        headline: "Someone hit reset. \(name) is full.",
                        mentionsTibo: false
                    ),
                    QuotaResetCaption(
                        eyebrow: "UNEXPECTED REFILL · \(name.uppercased())",
                        headline: "\(name) snapped back mid-window.",
                        mentionsTibo: false
                    ),
                    QuotaResetCaption(
                        eyebrow: "THE BUTTON · \(name.uppercased())",
                        headline: "An unscheduled \(name) refill just landed.",
                        mentionsTibo: false
                    )
                ]
            }
        case .bankedGrant:
            options = [
                QuotaResetCaption(
                    eyebrow: "RESET CARD · \(name.uppercased())",
                    headline: "A reset card landed. Use it before it expires.",
                    mentionsTibo: false
                ),
                QuotaResetCaption(
                    eyebrow: "BANKED · \(name.uppercased())",
                    headline: "\(name) banked a reset. Don’t let the card expire.",
                    mentionsTibo: false
                )
            ]
        case .bankedRedeem:
            options = [
                QuotaResetCaption(
                    eyebrow: "CARD REDEEMED · \(name.uppercased())",
                    headline: "Banked reset cashed. New \(windowWord) starts now.",
                    mentionsTibo: false
                ),
                QuotaResetCaption(
                    eyebrow: "VAULT OPEN · \(name.uppercased())",
                    headline: "You spent a reset card. \(name) is full.",
                    mentionsTibo: false
                )
            ]
        }

        let filtered = options.filter { $0.headline != lastHeadline }
        let pool = filtered.isEmpty ? options : filtered
        return pool[stableIndex(seed: seed, count: pool.count)]
    }

    public static func choreography(
        kind: QuotaResetKind,
        providerToken: String,
        surpriseCountLastDay: Int,
        lastHeadline: String?,
        seed: String
    ) -> QuotaResetChoreography {
        let isCodex = providerToken == "codex" || providerToken == "openai"
        switch kind {
        case .scheduled:
            return pick(
                [.calendarTear, .clockStrike, .moonCycle, .emberRekindle],
                seed: seed
            )
        case .surprise:
            if isCodex && surpriseCountLastDay >= 1 {
                return .doubleTap
            }
            if isCodex {
                return pick([.plungerSlam, .dashboardFall, .tiboHand], seed: seed)
            }
            return pick([.plungerSlam, .dashboardFall], seed: seed)
        case .bankedGrant:
            return pick([.foilCard, .bankerStamp], seed: seed)
        case .bankedRedeem:
            return pick([.vaultFlood, .hourglassFlip], seed: seed)
        }
    }

    public static func coalescedCaption(providers: [String]) -> QuotaResetCaption {
        let names = providers.map { $0 }.joined(separator: " · ")
        return QuotaResetCaption(
            eyebrow: "WINDOWS ROLLED",
            headline: providers.count == 1
                ? "A weekly window rolled while you were away."
                : "\(providers.count) windows rolled. \(names).",
            mentionsTibo: false
        )
    }

    private static func windowLabel(_ windowClass: QuotaResetWindowClass) -> String {
        switch windowClass {
        case .session: return "session"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .daily: return "daily"
        case .other: return "quota"
        }
    }

    private static func pick(_ options: [QuotaResetChoreography], seed: String) -> QuotaResetChoreography {
        options[stableIndex(seed: seed, count: options.count)]
    }

    private static func stableIndex(seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 5_381
        for byte in seed.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return Int(hash % UInt64(count))
    }
}
