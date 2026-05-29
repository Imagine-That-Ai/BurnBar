import Foundation

/// Timing policy for the locked-screen credential bridge.
///
/// A synthetic key press sent while the display is asleep can be consumed by
/// macOS as "wake the display" instead of focusing the password field. Remote
/// Unlock therefore wakes first, waits for loginwindow to redraw, then sends the
/// focus key and password.
public enum RemoteAccessDisplayWakePolicy {
    public static let awakeSettleDelayMicroseconds: UInt32 = 150_000
    public static let asleepSettleDelayMicroseconds: UInt32 = 900_000

    public static func settleDelayMicroseconds(displayWasAsleep: Bool) -> UInt32 {
        displayWasAsleep ? asleepSettleDelayMicroseconds : awakeSettleDelayMicroseconds
    }
}
