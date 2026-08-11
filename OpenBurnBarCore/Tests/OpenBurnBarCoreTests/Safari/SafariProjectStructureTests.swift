import Foundation
import XCTest

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

    func test_entitlementsAreSandboxedAndExposeOnlyRequiredSharedCapabilities() throws {
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
        XCTAssertEqual(
            entitlements["com.apple.security.application-groups"] as? [String],
            ["group.com.openburnbar.app"]
        )
        XCTAssertEqual(
            entitlements["keychain-access-groups"] as? [String],
            ["$(AppIdentifierPrefix)com.openburnbar.app"]
        )
        XCTAssertNil(
            entitlements["com.apple.security.keychain-access-groups"],
            "Use the canonical code-signing entitlement key, not a sandbox-prefixed lookalike."
        )
    }

    func test_projectEmbedsAnAttenuatedSignedSafariExtension() throws {
        let project = try String(
            contentsOf: repositoryRoot().appendingPathComponent("project.yml"),
            encoding: .utf8
        )
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
            )
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
        XCTAssertTrue(safari.contains("product: OpenBurnBarKernel"))
        XCTAssertFalse(
            safari.contains("product: OpenBurnBarCore"),
            "The appex must depend on the narrow UI-free Kernel, not the umbrella Core product."
        )
    }

    func test_webResourcesAreBuiltOnceAndCopiedIntoTheCanonicalBundleRoot() throws {
        let root = repositoryRoot()
        let handler = try String(
            contentsOf: root.appendingPathComponent(
                "OpenBurnBarSafariExtension/SafariWebExtensionHandler.swift"
            ),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let safari = try XCTUnwrap(
            yamlTargetBlock(named: "OpenBurnBarSafariExtension", in: project)
        )

        for relativePath in [
            "OpenBurnBarSafariExtension/SafariWebExtensionHandler.swift",
            "OpenBurnBarSafariExtension/Info.plist",
            "OpenBurnBarSafariExtension/Resources/OpenBurnBarSafariExtension.entitlements",
            "extensions/safari/package.json",
            "extensions/safari/manifest.json",
            "extensions/safari/scripts/build.mjs"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(relativePath).path
                ),
                "Missing canonical Safari source artifact: \(relativePath)"
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
        XCTAssertTrue(
            safari.contains(
                "Contents/Resources/manifest.json"
            )
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
