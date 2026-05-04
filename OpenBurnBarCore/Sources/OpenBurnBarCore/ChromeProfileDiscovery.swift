import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Chrome Profile Info

/// Non-sensitive metadata about a Chrome profile discovered from Local State.
#if os(macOS)

public struct ChromeProfileInfo: Identifiable, Equatable, Sendable {
    /// The profile folder key (e.g., "Default", "Profile 1").
    public let folderKey: String
    /// Human-readable name from gaia_name or name fallback.
    public let displayName: String
    /// The user's email address (user_name field), if signed in.
    public let email: String?
    /// The hosted domain (work accounts), if applicable.
    public let hostedDomain: String?
    /// Best-effort detected web services currently signed into within this browser profile.
    public let serviceIdentities: [BrowserServiceIdentity]

    public var id: String { folderKey }

    public init(
        folderKey: String,
        displayName: String,
        email: String? = nil,
        hostedDomain: String? = nil,
        serviceIdentities: [BrowserServiceIdentity] = []
    ) {
        self.folderKey = folderKey
        self.displayName = displayName
        self.email = email
        self.hostedDomain = hostedDomain
        self.serviceIdentities = serviceIdentities
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
                hostedDomain: hostedDomain == "NO_HOSTED_DOMAIN" ? nil : hostedDomain,
                serviceIdentities: detectServiceIdentities(profileFolderKey: folderKey)
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

    static func detectServiceIdentities(profileFolderKey: String) -> [BrowserServiceIdentity] {
        let profileDir = "\(chromeSupportDir)/\(profileFolderKey)"
        return detectServiceIdentities(profileDirectoryPath: profileDir)
    }

    static func detectServiceIdentities(profileDirectoryPath: String) -> [BrowserServiceIdentity] {
        let fm = FileManager.default
        let storagePaths = [
            "\(profileDirectoryPath)/Local Storage/leveldb",
            "\(profileDirectoryPath)/IndexedDB",
        ]

        let candidateFiles = storagePaths.flatMap { storagePath in
            candidateStorageFiles(atPath: storagePath, fileManager: fm)
        }

        return BrowserServiceProvider.allCases.compactMap { provider in
            detectServiceIdentity(provider: provider, candidateFiles: candidateFiles, fileManager: fm)
        }
    }

    static func detectServiceIdentity(
        provider: BrowserServiceProvider,
        candidateFiles: [String],
        fileManager: FileManager = .default
    ) -> BrowserServiceIdentity? {
        var matched = false
        var candidateScores: [String: Int] = [:]

        for file in candidateFiles {
            guard let data = fileManager.contents(atPath: file) else { continue }

            let fileName = URL(fileURLWithPath: file).lastPathComponent.lowercased()
            let hasMarker = fileName.contains(provider.storageMarker)
                || dataContainsProviderMarker(data, provider: provider)
            guard hasMarker else { continue }

            matched = true

            for candidate in likelyAccountLabels(for: provider, in: data) {
                candidateScores[candidate, default: 0] += 1
            }
        }

        guard matched else { return nil }

        let bestLabel = candidateScores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .first?
            .key

        return BrowserServiceIdentity(provider: provider, accountLabel: bestLabel)
    }

    static func likelyAccountLabels(for _: BrowserServiceProvider, in data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var scores: [String: Int] = [:]

        guard let regex = try? NSRegularExpression(pattern: emailRegex, options: [.caseInsensitive]) else {
            return []
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, options: [], range: fullRange) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let candidate = normalizeAccountLabel(String(text[swiftRange]))
            guard isLikelyUserFacingAccountLabel(candidate) else { continue }

            var score = 1
            let contextLocation = max(0, match.range.location - 48)
            let contextLength = min(text.utf16.count - contextLocation, match.range.length + 96)
            let contextRange = NSRange(location: contextLocation, length: contextLength)
            if let swiftContextRange = Range(contextRange, in: text) {
                let context = text[swiftContextRange].lowercased()
                if context.contains("email") || context.contains("identifier") {
                    score += 3
                }
                if context.contains("account") || context.contains("user") {
                    score += 2
                }
            }
            scores[candidate, default: 0] += score
        }

        return scores
            .filter { $0.value >= 1 }
            .sorted {
                if $0.value == $1.value {
                    return $0.key < $1.key
                }
                return $0.value > $1.value
            }
            .map(\.key)
    }

    private static func candidateStorageFiles(atPath path: String, fileManager: FileManager) -> [String] {
        guard fileManager.fileExists(atPath: path) else { return [] }
        guard let enumerator = fileManager.enumerator(atPath: path) else { return [] }

        var files: [String] = []
        while let next = enumerator.nextObject() as? String {
            let fullPath = "\(path)/\(next)"
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }

            let lowercased = next.lowercased()
            if lowercased.hasSuffix(".ldb")
                || lowercased.hasSuffix(".log")
                || lowercased.contains("manifest") {
                files.append(fullPath)
            }
        }
        return files
    }

    private static func dataContainsProviderMarker(_ data: Data, provider: BrowserServiceProvider) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return provider.storageMarkers.contains { text.contains($0) }
    }

    private static func normalizeAccountLabel(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func isLikelyUserFacingAccountLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 120 else { return false }

        if value.contains("@") {
            guard value.range(of: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,24}$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                return false
            }

            let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].count >= 3 else { return false }

            let lowercased = value.lowercased()
            let excludedDomains = [
                "amazonaws.com",
                "example.com",
                "example.org",
                "example.net",
            ]
            return !excludedDomains.contains { lowercased.hasSuffix($0) }
        }

        return value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
    }

    private static let emailRegex = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,24}"#
}

private extension BrowserServiceProvider {
    var storageMarkers: [String] {
        switch self {
        case .openAI:
            return ["auth.openai.com", "chatgpt.com", "chat.openai.com", "openai"]
        case .claude:
            return ["claude.ai", "claude"]
        }
    }

    var storageMarker: String {
        storageMarkers[0]
    }
}


#endif