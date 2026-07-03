import Foundation
import OpenBurnBarCore

#if canImport(Darwin)
/// Delivers controller nudges by broadcasting to the OpenBurnBar app. The app posts a real
/// `UserNotifications` banner (same as the previous `osascript display notification` behavior,
/// without spawning `/usr/bin/osascript` or touching `UNUserNotificationCenter` from the helper).
actor BurnBarLocalNotificationBridge {
    static let shared = BurnBarLocalNotificationBridge()

    func deliver(title: String, body: String) async throws {
        let userInfo: [String: String] = [
            OpenBurnBarDistributedNotifications.titleKey: title,
            OpenBurnBarDistributedNotifications.bodyKey: body
        ]
        DistributedNotificationCenter.default().postNotificationName(
            OpenBurnBarDistributedNotifications.daemonLocalNotificationName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
#else
actor BurnBarLocalNotificationBridge {
    static let shared = BurnBarLocalNotificationBridge()

    func deliver(title: String, body: String) async throws {
        throw NSError(
            domain: "BurnBarLocalNotificationBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Local distributed notifications are unavailable on Linux."]
        )
    }
}
#endif
