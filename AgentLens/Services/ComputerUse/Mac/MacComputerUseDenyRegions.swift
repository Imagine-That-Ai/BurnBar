#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarComputerUseCore

/// Mac-runtime deny-region classifier for Path C.
///
/// Scope rules catch app/window/url level risks. This classifier catches
/// point-level AX risks right before a CGEvent is posted, such as secure
/// text fields and system authentication prompts. It is intentionally
/// data-shaped so tests can fixture AX snapshots without touching the
/// live accessibility tree.
public struct MacComputerUseDenyRegions: Sendable {
    public struct Element: Sendable, Equatable {
        public var role: String?
        public var subrole: String?
        public var roleDescription: String?
        public var label: String?
        public var title: String?
        public var bundleId: String?

        public init(
            role: String? = nil,
            subrole: String? = nil,
            roleDescription: String? = nil,
            label: String? = nil,
            title: String? = nil,
            bundleId: String? = nil
        ) {
            self.role = role
            self.subrole = subrole
            self.roleDescription = roleDescription
            self.label = label
            self.title = title
            self.bundleId = bundleId
        }
    }

    public var sensitiveBundles: Set<String>
    public var authKeywords: [String]

    public init(
        sensitiveBundles: Set<String> = [
            "com.apple.keychainaccess",
            "com.apple.SecurityAgent",
            "com.apple.SecurityAgentHelper",
            "com.apple.loginwindow",
            "com.apple.FileVaultRecoveryUtility"
        ],
        authKeywords: [String] = [
            "authenticate",
            "authentication",
            "authorize",
            "keychain",
            "login password",
            "password",
            "passcode",
            "privacy",
            "security"
        ]
    ) {
        self.sensitiveBundles = sensitiveBundles
        self.authKeywords = authKeywords
    }

    public func denyReason(for element: Element?) -> ComputerUseAccessibilityDenyReason? {
        guard let element else { return nil }
        if isSecureTextField(element) {
            return .secureTextField
        }
        if isSensitiveBundle(element.bundleId) {
            return .keychainPrompt
        }
        if isSystemAuthSurface(element) {
            return .systemAuthSheet
        }
        return nil
    }

    private func isSecureTextField(_ element: Element) -> Bool {
        element.role == "AXTextField" && element.subrole == "AXSecureTextField"
    }

    private func isSensitiveBundle(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return sensitiveBundles.contains(bundleId)
    }

    private func isSystemAuthSurface(_ element: Element) -> Bool {
        let roleHints = [
            element.role,
            element.subrole,
            element.roleDescription,
            element.label,
            element.title
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        guard !roleHints.isEmpty else { return false }
        let isSheetLike = roleHints.contains("sheet") || roleHints.contains("dialog")
        return isSheetLike && authKeywords.contains { roleHints.contains($0) }
    }
}
#endif
