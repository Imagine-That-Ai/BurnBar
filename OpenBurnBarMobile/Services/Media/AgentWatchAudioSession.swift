import Foundation
@preconcurrency import AVFoundation

/// Keeps sample-buffer PiP eligible while Agent Watch is live.
///
/// iOS only allows background PiP for an active playback-style session. We use
/// a silent `.playback` category for watch-only mirroring, but never overwrite
/// Mercury's `.playAndRecord` call session.
@MainActor
final class AgentWatchAudioSession {
    private(set) var isActive = false

    func activateForLiveWatchIfAllowed() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else {
            isActive = false
            return
        }

        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            isActive = true
        } catch {
            isActive = false
        }
    }

    func deactivate() {
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isActive = false
    }
}
