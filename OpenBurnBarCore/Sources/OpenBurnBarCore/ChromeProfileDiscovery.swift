import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Chrome Profile Info

/// Non-sensitive metadata about a Chrome profile discovered from Local State.
public struct ChromeProfileInfo: Identifiable, Equatable, Sendable {
    /// The profile folder key (e.g., "Default", "Profile 1").
    public let folderKey: String
    /// Human-readable name from gaia_name or name fallback.
    public let displayName: String
    /// The user's email address (user_name field), if signed in.
    public let email: String?
    /// The hosted domain (work accounts), if applicable.
    public let hostedDomain: String?

    public var id: String { folderKey }

    public init(folderKey: String, displayName: String, email: String? = nil, hostedDomain: String? = nil) {
        self.folderKey = folderKey
        self.displayName = displayName
        self.email = email
        self.hostedDomain = hostedDomain
    }
}

// MARK: - Chrome Profile Discovery

/// Discovers Chrome profiles by reading the Local State JSON file.
///
/// Security: Only reads non-sensitive profile listing metadata (folder keys, display names, emails).
/// This is the same data Chrome shows in its profile switcher UI.
/// No cookies, tokens, or session data are read.
public enum ChromeProfileDiscovery {

    /// The standard path to Chrome's Local State file.
    private static let localStatePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Google/Chrome/Local State"
    }()

    /// The Chrome application support directory.
    private static let chromeSupportDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Google/Chrome"
    }()

    /// Reads Chrome's Local State and returns all profile info.
    /// Returns empty array if Chrome not installed or Local State unreadable.
    public static func discoverProfiles() -> [ChromeProfileInfo] {
        let fm = FileManager.default

        guard fm.fileExists(atPath: localStatePath),
              let data = fm.contents(atPath: localStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: [String: Any]] else {
            return []
        }

        var profiles: [ChromeProfileInfo] = []

        for (folderKey, info) in infoCache.sorted(by: { $0.key == "Default" ? true : $0.key < $1.key }) {
            // Prefer gaia_name (signed-in name), fall back to local name
            let gaiaName = info["gaia_name"] as? String
            let localName = info["name"] as? String
            let displayName = gaiaName ?? localName ?? folderKey

            let email = info["user_name"] as? String
            let hostedDomain = info["hosted_domain"] as? String

            // Skip profiles with no sign-in info AND no local name (system profiles)
            let isSystemProfile = (email == nil || email?.isEmpty == true)
                && gaiaName == nil
                && (localName == nil || localName == folderKey)

            if isSystemProfile { continue }

            let profileInfo = ChromeProfileInfo(
                folderKey: folderKey,
                displayName: displayName,
                email: email,
                hostedDomain: hostedDomain == "NO_HOSTED_DOMAIN" ? nil : hostedDomain
            )
            profiles.append(profileInfo)
        }

        return profiles
    }

    /// Validates that a profile folder actually exists on disk.
    public static func validateProfileFolder(_ folderKey: String) -> Bool {
        let profileDir = "\(chromeSupportDir)/\(folderKey)"
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: profileDir, isDirectory: &isDir) && isDir.boolValue
    }

    /// Checks if Chrome is installed on this system.
    public static func isChromeInstalled() -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
        #else
        return FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app")
        #endif
    }
}
