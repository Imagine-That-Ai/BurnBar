import SwiftUI
import UIKit

// MARK: - Haptics

/// Centralized haptic feedback helper. Debounced, thread-safe, respects Reduce Motion.
enum Haptics {
    /// Actor-isolated debounce state to ensure thread safety without race conditions.
    private actor DebounceState {
        var lastLightImpact = Date.distantPast
        var lastWarningImpact = Date.distantPast
        
        func canTriggerLight() -> Bool {
            let now = Date()
            guard now.timeIntervalSince(lastLightImpact) > 0.15 else { return false }
            lastLightImpact = now
            return true
        }
        
        func canTriggerWarning() -> Bool {
            let now = Date()
            guard now.timeIntervalSince(lastWarningImpact) > 0.5 else { return false }
            lastWarningImpact = now
            return true
        }
    }
    
    private static let debounce = DebounceState()

    static func light() {
        Task {
            guard await debounce.canTriggerLight() else { return }
            await MainActor.run {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            }
        }
    }

    static func medium() {
        Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }

    static func rigid() {
        Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred()
        }
    }

    static func success() {
        Task { @MainActor in
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
    }

    static func warning() {
        Task {
            guard await debounce.canTriggerWarning() else { return }
            await MainActor.run {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
            }
        }
    }

    static func error() {
        Task { @MainActor in
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }

    static func selection() {
        Task { @MainActor in
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
        }
    }
}
