import Foundation
import XCTest

/// Tripwire for the packaging path that makes the committed Safari web extension
/// actually ship. Before this existed, `extensions/safari/dist` was committed but no
/// target consumed it, nothing embedded it, and nothing signed it — so it shipped in
/// no release, silently and with no red check anywhere.
final class SafariProjectStructureTests: XCTestCase {
    func test_infoPlistDeclaresCanonicalSafariEntrypointAndInheritedVersions() throws {
        let info = try propertyList(
            at: repositoryRoot()
                .appendingPathComponent("OpenBurnBarSafariExtension/Info.plist")
        )
        let extensionInfo = try XCTUnwrap(info["NSExtension"] as? [String: Any])

        XCTAssertEqual(
            extensionInfo["NSExtensionPointIdentifier"] as? String,
            "com.apple.Safari.web-extension"
        )
        XCTAssertEqual(
            extensionInfo["NSExtensionPrincipalClass"] as? String,
            "$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler"
        )
        XCTAssertEqual(
            info["CFBundleShortVersionString"] as? String,
            "$(MARKETING_VERSION)"
        )
        XCTAssertEqual(
            info["CFBundleVersion"] as? String,
            "$(CURRENT_PROJECT_VERSION)"
        )
    }

    func test_entitlementsAreSandboxedAndClaimNoProfileRestrictedCapabilities() throws {
        let entitlements = try propertyList(
            at: repositoryRoot()
                .appendingPathComponent(
                    "OpenBurnBarSafariExtension/Resources/OpenBurnBarSafariExtension.entitlements"
                )
        )

        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
        XCTAssertNil(
            entitlements["com.apple.security.network.server"],
            "The Safari appex is a loopback client and must not listen for inbound traffic."
        )
        XCTAssertNil(
            entitlements["com.apple.security.application-groups"],
            """
            App Groups are profile-restricted for Developer ID. Claiming one without a \
            MAC_APP_DIRECT profile for com.openburnbar.app.safari-extension makes the \
            website release lane fail closed. It lands with the native bridge and its profile.
            """
        )
        XCTAssertNil(
            entitlements["keychain-access-groups"],
            """
            Keychain Sharing is profile-restricted for Developer ID; same constraint as \
            App Groups above.
            """
        )
        XCTAssertNil(
            entitlements["com.apple.security.keychain-access-groups"],
            "Use the canonical code-signing entitlement key, not a sandbox-prefixed lookalike."
        )
    }

    func test_projectEmbedsAnAttenuatedSignedSafariExtension() throws {
        let project = try projectSpecification()
        let host = try XCTUnwrap(yamlTargetBlock(named: "OpenBurnBar", in: project))
        let safari = try XCTUnwrap(
            yamlTargetBlock(named: "OpenBurnBarSafariExtension", in: project)
        )

        XCTAssertTrue(
            project.contains(
                "OPENBURNBAR_HOST_CODE_SIGN_ENTITLEMENTS: AgentLens/Resources/OpenBurnBar.entitlements"
            )
        )
        XCTAssertTrue(
            host.contains(
                "CODE_SIGN_ENTITLEMENTS: \"$(OPENBURNBAR_HOST_CODE_SIGN_ENTITLEMENTS)\""
            ),
            """
            The host must read its entitlements through the indirection so a command-line \
            CODE_SIGN_ENTITLEMENTS= (the Mac App Store lane passes one) cannot stamp host \
            entitlements onto the embedded extension.
            """
        )
        XCTAssertTrue(host.contains("- target: OpenBurnBarSafariExtension"))
        XCTAssertTrue(host.contains("codeSign: true"))

        XCTAssertTrue(safari.contains("type: app-extension"))
        XCTAssertTrue(safari.contains("platform: macOS"))
        XCTAssertTrue(safari.contains("path: OpenBurnBarSafariExtension/Info.plist"))
        XCTAssertTrue(
            safari.contains(
                "PRODUCT_BUNDLE_IDENTIFIER: com.openburnbar.app.safari-extension"
            )
        )
        XCTAssertTrue(
            safari.contains(
                "CODE_SIGN_ENTITLEMENTS: OpenBurnBarSafariExtension/Resources/OpenBurnBarSafariExtension.entitlements"
            )
        )
        XCTAssertTrue(safari.contains("APPLICATION_EXTENSION_API_ONLY: YES"))
        XCTAssertTrue(safari.contains("ENABLE_HARDENED_RUNTIME: YES"))
        XCTAssertTrue(safari.contains("SKIP_INSTALL: YES"))
        XCTAssertTrue(safari.contains("- sdk: SafariServices.framework"))
        XCTAssertFalse(
            safari.contains("package: OpenBurnBarCore"),
            """
            The appex links no OpenBurnBar module. The native bridge it would need depends \
            on Safari RPC methods and daemon handlers that are not on main, so linking Core \
            here drags the unlanded Safari program into the release path.
            """
        )
    }

    func test_webResourcesShipFromTheCommittedBundleIntoTheCanonicalBundleRoot() throws {
        let root = repositoryRoot()
        let handler = try String(
            contentsOf: root.appendingPathComponent(
                "OpenBurnBarSafariExtension/SafariWebExtensionHandler.swift"
            ),
            encoding: .utf8
        )
        let safari = try XCTUnwrap(
            yamlTargetBlock(
                named: "OpenBurnBarSafariExtension",
                in: try projectSpecification()
            )
        )

        for relativePath in [
            "OpenBurnBarSafariExtension/SafariWebExtensionHandler.swift",
            "OpenBurnBarSafariExtension/Info.plist",
            "OpenBurnBarSafariExtension/Resources/OpenBurnBarSafariExtension.entitlements",
            "extensions/safari/dist/manifest.json",
            "extensions/safari/dist/background.js",
            "extensions/safari/dist/content.js",
            "extensions/safari/dist/popup.html",
            "extensions/safari/dist/icons/app-icon-128.png"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(relativePath).path
                ),
                "Missing canonical Safari artifact: \(relativePath)"
            )
        }
        XCTAssertTrue(
            handler.contains(
                "final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling"
            )
        )
        XCTAssertFalse(
            handler.contains("@objc(SafariWebExtensionHandler)"),
            "The plist uses the module-qualified Swift class name; an explicit unqualified Objective-C rename breaks lookup."
        )

        XCTAssertTrue(safari.contains("DIST_DIR=\"${PROJECT_DIR}/extensions/safari/dist\""))
        XCTAssertTrue(safari.contains("MANIFEST=\"${DIST_DIR}/manifest.json\""))
        XCTAssertTrue(
            safari.contains(
                "RESOURCES_DIR=\"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}\""
            )
        )
        XCTAssertTrue(
            safari.contains(
                "/usr/bin/rsync -a --delete \"${DIST_DIR}/\" \"${RESOURCES_DIR}/\""
            )
        )
        XCTAssertTrue(safari.contains("Contents/Resources/manifest.json"))
    }

    /// The build embeds the appex; only the release script signs it. Xcode builds the
    /// app with CODE_SIGNING_ALLOWED=NO, so an unsigned nested appex would sail through
    /// the build and then fail `codesign --verify --deep --strict` — including the
    /// public-download trust gate that runs against the published artifact.
    func test_websiteReleaseSignsTheEmbeddedSafariExtension() throws {
        let release = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("scripts/build-macos-website-release.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(
            release.contains("$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"),
            "The website release must sign the embedded Safari appex before it signs the app."
        )
        XCTAssertTrue(
            release.contains("safari_extension_entitlements"),
            "The appex must be signed with its own attenuated entitlements, not the host's."
        )
        XCTAssertTrue(
            release.contains("com.openburnbar.app.safari-extension"),
            "The appex signature must carry its own identifier."
        )
    }

    private func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("project.yml").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        XCTFail("Could not locate the repository root from \(#filePath)")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func projectSpecification() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent("project.yml"),
            encoding: .utf8
        )
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(
            value as? [String: Any],
            "Expected a dictionary property list at \(url.path)"
        )
    }

    private func yamlTargetBlock(named name: String, in yaml: String) -> String? {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0 == "  \(name):" }) else {
            return nil
        }
        var end = lines.endIndex
        for index in lines.index(after: start)..<lines.endIndex {
            let line = lines[index]
            if line.hasPrefix("  "),
               !line.hasPrefix("    "),
               line.hasSuffix(":") {
                end = index
                break
            }
        }
        return lines[start..<end].joined(separator: "\n")
    }
}
