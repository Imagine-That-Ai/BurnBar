import AppKit
import AudioToolbox
import Foundation

// MARK: - Receipt Audio Player

/// Plays a subtle, tactile thermal printer / register sound when a fresh receipt prints.
@MainActor
public enum ReceiptAudioPlayer {

    public static func playReceiptPrintSound(enabled: Bool = true) {
        guard enabled else { return }

        // Attempt to play subtle printer/register tactile feedback
        // macOS System Sound 1054 / 1057 (Tink / Pop) or named sound
        if let sound = NSSound(named: "Pop") ?? NSSound(named: "Tink") ?? NSSound(named: "Purr") {
            sound.volume = 0.55
            sound.play()
        } else {
            // Fallback to standard system sound ID
            AudioServicesPlaySystemSound(1057)
        }
    }

    public static func playQualityAuditStampSound(enabled: Bool = true) {
        guard enabled else { return }

        if let sound = NSSound(named: "Blow") ?? NSSound(named: "Hero") {
            sound.volume = 0.6
            sound.play()
        } else {
            AudioServicesPlaySystemSound(1001)
        }
    }
}
