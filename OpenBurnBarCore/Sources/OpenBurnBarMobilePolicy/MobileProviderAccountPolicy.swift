import Foundation

public enum MobileProviderConnectivity: String, Sendable, Equatable {
    case localOnly = "local-only"
    case cloudConnected = "cloud-connected"
}

public enum MobileProviderErrorClass: String, Sendable, Equatable, CaseIterable {
    case denied
    case offline
    case expired
    case malformed

    public var userVisibleLabel: String {
        switch self {
        case .denied: return "Permission denied"
        case .offline: return "Offline"
        case .expired: return "Credential expired"
        case .malformed: return "Provider data is malformed"
        }
    }
}

public enum MobileProviderAccountPolicy {
    public static func connectivity(storageScope: String) -> MobileProviderConnectivity {
        switch storageScope {
        case "cloud_refreshable", "server_private":
            return .cloudConnected
        default:
            return .localOnly
        }
    }

    /// Local-only / device-keychain accounts never count as cloud-connected.
    public static func isCloudConnected(storageScope: String) -> Bool {
        connectivity(storageScope: storageScope) == .cloudConnected
    }

    public static func classifyError(code: String, message: String? = nil) -> MobileProviderErrorClass {
        let haystack = [code, message ?? ""]
            .joined(separator: " ")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if haystack.contains("permission-denied") || haystack.contains("permissiondenied")
            || haystack.contains("denied") {
            return .denied
        }
        if haystack.contains("unavailable") || haystack.contains("network") || haystack.contains("offline")
            || haystack.contains("deadline-exceeded") {
            return .offline
        }
        if haystack.contains("expired") && !haystack.contains("deadline-exceeded") {
            return .expired
        }
        return .malformed
    }
}
