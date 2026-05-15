import Foundation

#if DEBUG
enum MobileE2ERoute {
    static var isCloudStoreRoute: Bool {
        route == "cloud-store" || route == "cloud"
    }

    private static var route: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["OPENBURNBAR_E2E_ROUTE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
#endif
