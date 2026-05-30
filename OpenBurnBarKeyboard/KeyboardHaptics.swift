import UIKit

// MARK: - Keyboard Haptics
/// Provides tactile feedback for key presses in the custom keyboard,
/// matching the native Apple keyboard feel.
///
/// Uses `UIImpactFeedbackGenerator` with different intensities:
/// - **Light**: Standard letter key presses
/// - **Medium**: Special keys (shift, delete, return, globe)
/// - **Rigid**: Suggestion/snippet selection
@MainActor
enum KeyboardHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    /// Call during `viewWillAppear` to warm up the Taptic Engine.
    static func prepare() {
        light.prepare()
        medium.prepare()
    }

    /// Standard letter key tap — subtle, fast.
    static func keyPress() {
        light.impactOccurred(intensity: 0.6)
    }

    /// Special key tap (shift, delete, globe, return) — slightly stronger.
    static func specialKeyPress() {
        medium.impactOccurred(intensity: 0.5)
    }

    /// Suggestion or snippet selection — distinct confirmation feel.
    static func selectionPress() {
        rigid.impactOccurred(intensity: 0.7)
    }
}
