import Foundation

/// Developer-ID release lane capabilities — absent entitlements must degrade visibly, not silently.
public struct DeveloperIDReleaseCapability: Sendable, Equatable {
    public var keychainAccessGroups: Bool
    public var iCloudDocuments: Bool
    public var appleSignIn: Bool

    public init(
        keychainAccessGroups: Bool,
        iCloudDocuments: Bool,
        appleSignIn: Bool
    ) {
        self.keychainAccessGroups = keychainAccessGroups
        self.iCloudDocuments = iCloudDocuments
        self.appleSignIn = appleSignIn
    }

    /// Parses an entitlements plist on disk (used by release smoke tests and runtime probes).
    public static func fromEntitlementsPlist(at url: URL) -> DeveloperIDReleaseCapability? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            return nil
        }
        return fromEntitlementsDictionary(plist)
    }

    public static func fromEntitlementsDictionary(_ plist: [String: Any]) -> DeveloperIDReleaseCapability {
        let keychain = (plist["keychain-access-groups"] as? [Any])?.isEmpty == false
        let iCloud = (plist["com.apple.developer.icloud-services"] as? [Any])?.isEmpty == false
        let signIn = (plist["com.apple.developer.applesignin"] as? [Any])?.isEmpty == false
        return DeveloperIDReleaseCapability(
            keychainAccessGroups: keychain,
            iCloudDocuments: iCloud,
            appleSignIn: signIn
        )
    }

    /// Expected capability matrix for `OpenBurnBarRelease.entitlements` (Developer-ID website build).
    public static let expectedDeveloperIDRelease = DeveloperIDReleaseCapability(
        keychainAccessGroups: false,
        iCloudDocuments: false,
        appleSignIn: false
    )

    /// Full Mac app entitlements (`OpenBurnBar.entitlements`) used for debug / profiled builds.
    public static let expectedFullMacApp = DeveloperIDReleaseCapability(
        keychainAccessGroups: true,
        iCloudDocuments: true,
        appleSignIn: true
    )
}
