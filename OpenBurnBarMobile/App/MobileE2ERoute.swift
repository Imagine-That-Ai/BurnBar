import Foundation

#if DEBUG
enum MobileE2ERoute {
    static var isCloudStoreRoute: Bool {
        route == "cloud-store" || route == "cloud"
    }

    static var isRemoteUnlockRoute: Bool {
        route == "remote-unlock" || route == "unlock"
    }

    static var allowsGuestCloudStore: Bool {
        ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_CLOUD_STORE_GUEST"] == "1"
    }

    private static var route: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["OPENBURNBAR_E2E_ROUTE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
#endif
