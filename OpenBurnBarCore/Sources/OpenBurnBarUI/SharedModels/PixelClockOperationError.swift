// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Shared `NSError` factory for the macOS (`MacPixelClockOperationsAdapter`) and iOS
/// (`MobilePixelClockOperationsAdapter`) Pixel Clock backends. Both build plain
/// `NSError`s on the `"PixelClock"` domain; only the platform-specific codes and
/// messages differ, so those stay at the call sites.
public enum PixelClockOperationError {
    public static let domain = "PixelClock"

    public static func failure(code: Int, message: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
