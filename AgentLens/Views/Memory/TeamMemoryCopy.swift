import Foundation

/// Canonical user-facing copy strings for Team Memory spaces (D16 / P20 §6 / P22).
///
/// These strings explicitly communicate the two immutable operational semantics:
/// (a) Join-reads-history: joining grants read of existing historical team memories.
/// (b) Leave-protects-future-only: leaving rotates keys for future writes, but cannot
///     claw back previously downloaded facts or keys from local devices.
public enum TeamMemoryCopy {
    public static let joinHeader = "Join Team Memory Space"

    public static let joinSemanticA =
        "Joining a team grants read access to all team memories sealed under the team's active keys, including memories contributed by team members before you joined."

    public static let leaveSemanticB =
        "Leaving or being removed from a team revokes your server access and rotates the team encryption key for future memories. However, it cannot erase memories or keys that have already been downloaded to your devices."

    public static let settingsFootnote =
        "Team memories are protected by zero-knowledge encryption. Only active team members hold the encryption keys. Joining a team grants access to past team memories; leaving rotates encryption keys to protect future memories only."

    public static let alertTitle = "Remove Member from Team?"
    public static let alertDestructiveAction = "Rotate Keys and Remove"

    public static let teamFactBadgeLabel = "Team Fact"
}
