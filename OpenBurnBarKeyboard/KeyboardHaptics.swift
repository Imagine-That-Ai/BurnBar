import UIKit

// MARK: - Keyboard Haptics
/// Provides tactile feedback for key presses in the custom keyboard extension.
///
/// Keeps persistent static instances of `UIImpactFeedbackGenerator` alive to prevent
/// immediate deallocation (which cancels the asynchronous haptic playback).
@MainActor
enum KeyboardHaptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)

    /// Warm-up call to prepare the generators and reduce latency on the first tap.
    static func prepare() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        rigidGenerator.prepare()
    }

    /// Standard letter key tap — subtle, fast.
    static func keyPress() {
        lightGenerator.prepare()
        lightGenerator.impactOccurred(intensity: 0.6)
    }

    /// Special key tap (shift, delete, globe, return) — slightly stronger.
    static func specialKeyPress() {
        mediumGenerator.prepare()
        mediumGenerator.impactOccurred(intensity: 0.5)
    }

    /// Suggestion or snippet selection — distinct confirmation feel.
    static func selectionPress() {
        rigidGenerator.prepare()
        rigidGenerator.impactOccurred(intensity: 0.7)
    }
}
