import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Three-step haptics intensity for the Mercury Live screen. `.gentle`
/// is the default — `.crisp` swaps soft impacts for sharp medium
/// impacts; `.off` disables all hapticgenerators on this screen.
enum MercuryHapticsLevel: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case off
    case gentle
    case crisp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:    return "Off"
        case .gentle: return "Gentle"
        case .crisp:  return "Crisp"
        }
    }

    var icon: String {
        switch self {
        case .off:    return "iphone.slash"
        case .gentle: return "iphone.radiowaves.left.and.right"
        case .crisp:  return "iphone.gen3.radiowaves.left.and.right"
        }
    }

    /// Plays a small sample haptic so the user feels the choice. No-op
    /// on platforms without `UIImpactFeedbackGenerator` (macOS unit tests).
    @MainActor
    func play() {
        #if canImport(UIKit)
        switch self {
        case .off:
            return
        case .gentle:
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.prepare()
            generator.impactOccurred(intensity: 0.65)
        case .crisp:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred(intensity: 0.9)
        }
        #endif
    }
}
