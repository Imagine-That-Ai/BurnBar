import Foundation
import OpenBurnBarCore

// MARK: - Agent Brand-Zone Quick-Action Composer (Hermes Square §6.3)
//
// Pure prompt/topic composition for the brand zone's quick actions. Moved
// out of `Views/Hermes/Square/AgentBrandZoneView.swift` (audit wave 4,
// item 15) into the Services layer it always belonged to; this file
// previously carried a placeholder comment pointing back at the view.

/// Snapshot of the most recent conversation context a Forward hands to the
/// destination agent.
struct AgentForwardContextSnapshot: Equatable, Sendable {
    let title: String
    let preview: String
    let sourceLabel: String
    let updatedAt: Date
}

enum AgentBrandQuickActionComposer {
    static let defaultSubscriptionTopicID = "agent-updates"

    static func defaultSubscriptionTopic(
        for identity: AgentIdentity,
        cadence: AgentManifest.PushTopic.Cadence,
        now: Date = Date()
    ) -> SubscriptionTopic {
        SubscriptionTopic(
            agentURI: identity.id,
            topicID: defaultSubscriptionTopicID,
            displayName: "\(identity.displayName) updates",
            description: identity.tier == .subscription
                ? "Scheduled updates from \(identity.displayName)."
                : "Mission and thread activity digests from \(identity.displayName).",
            cadence: cadence,
            consentGivenAt: now,
            isMuted: false,
            deliveryCountThisMonth: 0,
            lastDeliveredAt: nil
        )
    }

    static func newThreadKickoffPrompt(for identity: AgentIdentity) -> String {
        """
        Start a new \(identity.displayName) thread.
        1) Ask me for the exact objective, constraints, and success criteria.
        2) Confirm the target project/path before doing any tool actions.
        3) Wait for my go-ahead.
        """
    }

    static func forwardPrompt(
        source: AgentIdentity,
        destination: AgentIdentity,
        context: AgentForwardContextSnapshot?,
        note: String,
        now: Date = Date()
    ) -> String {
        let noteLine = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = iso8601String(from: now)

        var sections: [String] = []
        sections.append("Forwarded from \(source.displayName) to \(destination.displayName) at \(timestamp).")

        if let context {
            sections.append(
                """
                Source context (\(context.sourceLabel)):
                - Title: \(context.title)
                - Preview: \(context.preview)
                - Updated: \(iso8601String(from: context.updatedAt))
                """
            )
        } else {
            sections.append("No thread transcript was available from \(source.displayName); use this as a fresh continuation request.")
        }

        if !noteLine.isEmpty {
            sections.append("Operator note: \(noteLine)")
        }

        sections.append(
            """
            Continue this work as a new thread.
            If anything is ambiguous, ask concise clarifying questions first.
            """
        )

        return sections.joined(separator: "\n\n")
    }

    private static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter.string(
            from: date,
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            formatOptions: [.withInternetDateTime]
        )
    }
}
