import SwiftUI
import UIKit

// MARK: - HapticBus
//
// Centralized haptic feedback bus. Wraps `Haptics` with semantic labels per
// interaction type so we never sprinkle raw impact calls through view code.
// Every Aurora component routes through this enum.

enum HapticBus {

    // MARK: - Semantic Events

    /// Tab change in the bottom tab bar.
    static func tabChange() { Haptics.selection() }

    /// Filter chip / segmented control swap.
    static func chipChange() { Haptics.light() }

    /// Pull-to-refresh started (rigid for confidence).
    static func refreshStarted() { Haptics.rigid() }

    /// Pull-to-refresh succeeded (success notification).
    static func refreshFinished() { Haptics.success() }

    /// User pressed a primary CTA (medium impact).
    static func primaryAction() { Haptics.medium() }

    /// User opened a sheet or expanded a moment.
    static func sheetOpen() { Haptics.light() }

    /// Toggle / switch.
    static func toggle() { Haptics.selection() }

    /// Sending a chat message — rigid for "launch" feel.
    static func send() { Haptics.rigid() }

    /// Threshold breach (warning level).
    static func threshold() { Haptics.warning() }

    /// Destructive confirm (sign out, delete).
    static func destructive() { Haptics.error() }

    /// Trend delta crossed a positive threshold (success "ping").
    static func milestone() { Haptics.success() }
}
