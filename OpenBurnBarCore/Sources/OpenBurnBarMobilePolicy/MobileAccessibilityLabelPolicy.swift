import Foundation

/// Spoken labels shared by Pulse/Burn/Hermes/Inbox. Source of the contract is
/// `docs/mobile-parity/fixtures/product/a11y-contract-vectors.json`.
public enum MobileAccessibilityLabelPolicy {
    public static func heroBurn(displayMode: String, heroText: String, liveRate: String?) -> String {
        var parts = ["Hero burn", displayMode, heroText]
        if let liveRate, !liveRate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("live rate \(liveRate)")
        }
        return parts.joined(separator: ", ")
    }

    public static func quotaPercentRemaining(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    public static func quotaRing(label: String, percentRemaining: Int) -> String {
        "\(label), \(percentRemaining) percent remaining"
    }

    public static func quotaRing(label: String, remainingFraction: Double) -> String {
        quotaRing(label: label, percentRemaining: quotaPercentRemaining(remainingFraction))
    }

    public static func chart(label: String, summary: String) -> String {
        "\(label), \(summary)"
    }

    public static func iconOnly(action: String) -> String { action }

    public static func loading(surface: String) -> String { "\(surface) loading" }

    public static func error(surface: String) -> String { "\(surface) failed to load" }

    public static func liveStream(surface: String) -> String { "\(surface) live" }

    public static func stopButton(isStreaming: Bool) -> String {
        isStreaming ? "Stop generating" : "Send"
    }

    public static func inboxRow(
        unread: Bool,
        kindLabel: String,
        priorityLabel: String?,
        title: String
    ) -> String {
        var parts: [String] = []
        if unread { parts.append("Unread") }
        parts.append(kindLabel)
        if let priorityLabel, !priorityLabel.isEmpty { parts.append(priorityLabel) }
        parts.append(title)
        return parts.joined(separator: ", ")
    }
}
