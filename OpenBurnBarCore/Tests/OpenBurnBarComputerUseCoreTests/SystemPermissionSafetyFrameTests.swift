import XCTest
@testable import OpenBurnBarComputerUseCore

/// Guards the copy that a nervous user reads immediately before macOS's own dialog.
///
/// These are copy tests, which usually earn their keep poorly. These do, for one
/// reason: the claim in `test_whereItGoes_neverClaimsDataStaysOnThisMac` was already
/// written wrong once during planning. "Screenshots stay on this Mac" is false --
/// tool results, screenshot content included, are returned to the configured model
/// provider (`OpenAICompatibleChatGatewayClient+ToolLoop` scrubs secrets precisely
/// because that content leaves for the provider), and frames go peer-to-peer to a
/// paired iPhone during Agent Watch. Shipping that sentence on a trust surface would
/// be worse than shipping nothing there.
final class SystemPermissionSafetyFrameTests: XCTestCase {

    private var allKinds: [SystemPermissionKind] { SystemPermissionKind.allCases }

    func test_everyKindHasACompleteSafetyFrame() {
        for kind in allKinds {
            let frame = kind.safetyFrame
            XCTAssertFalse(frame.whoWatches.isEmpty, "\(kind) is missing whoWatches")
            XCTAssertFalse(frame.whereItGoes.isEmpty, "\(kind) is missing whereItGoes")
            XCTAssertFalse(frame.whoDrives.isEmpty, "\(kind) is missing whoDrives")
            XCTAssertFalse(frame.ifYouDecline.isEmpty, "\(kind) is missing ifYouDecline")
            XCTAssertFalse(frame.howToRevoke.isEmpty, "\(kind) is missing howToRevoke")
        }
    }

    /// The load-bearing test. Any phrasing that promises data never leaves the machine
    /// is banned for kinds whose output is handed to a model provider or a paired
    /// device. If a future edit reintroduces it, this fails.
    func test_whereItGoes_neverClaimsDataStaysOnThisMac() {
        // Kinds whose captured content demonstrably leaves this Mac.
        let leavesTheMac: Set<SystemPermissionKind> = [
            .screenRecording,   // tool result -> model provider; frames -> paired iPhone
            .accessibility,     // AX labels ride along in tool results
            .automation,        // read from the target app rides along in tool results
            .camera,            // peer-to-peer to the far end of the call
            .microphone,        // peer-to-peer to the far end of the call
            .remoteDesktop      // frames -> paired device
        ]

        let bannedPhrases = [
            "never leaves",
            "stays on this mac",
            "stay on this mac",
            "stays on your mac",
            "stay on your mac",
            "only on this mac",
            "goes nowhere"
        ]

        for kind in leavesTheMac {
            let haystack = kind.safetyFrame.whereItGoes.lowercased()
            for phrase in bannedPhrases {
                XCTAssertFalse(
                    haystack.contains(phrase),
                    """
                    \(kind).safetyFrame.whereItGoes claims "\(phrase)", but this kind's \
                    captured content leaves this Mac (model provider and/or a paired device). \
                    Describe where it actually goes instead -- an overclaim here costs more \
                    trust than it buys.
                    """
                )
            }
        }
    }

    /// Avoiding "stays on this Mac" is not enough: silence about the destination is its
    /// own kind of overclaim. Every kind whose captured content is handed to the model
    /// provider must *say so*.
    ///
    /// Added after review caught the accessibility frame describing only the local audit
    /// log, while AX labels, window titles and URLs are returned as tool results and sent
    /// onward exactly like a screenshot.
    func test_kindsThatReachTheModelProviderSaySo() {
        let reachesProvider: Set<SystemPermissionKind> = [
            .screenRecording, .accessibility, .automation, .fullDiskAccess
        ]
        for kind in reachesProvider {
            let text = kind.safetyFrame.whereItGoes.lowercased()
            XCTAssertTrue(
                text.contains("provider"),
                "\(kind).safetyFrame.whereItGoes must name the model provider: content this "
                + "permission exposes is returned as a tool result and sent to whichever "
                + "provider the user configured, so describing only the local log implies "
                + "it stays here."
            )
        }
    }

    /// Per-action approval is a property of the *session mode*, not of the permission.
    /// Manual stops for everything; Step lets one approval cover a burst of up to ten
    /// similar actions or thirty seconds; Trusted dispatches scoped actions without
    /// asking. Promising unconditional approval on a consent surface is false for two of
    /// the three modes.
    func test_noFrameClaimsUnconditionalPerActionApproval() {
        let bannedPhrases = [
            "every action stops for your approval",
            "every action needs your approval",
            "every click and keystroke stops",
            "every action requires your approval"
        ]
        for kind in allKinds {
            let text = kind.safetyFrame.whoDrives.lowercased()
            for phrase in bannedPhrases {
                XCTAssertFalse(
                    text.contains(phrase),
                    "\(kind).safetyFrame.whoDrives promises \"\(phrase)\", which is false in "
                    + "Step and Trusted modes. Describe the modes instead of promising an "
                    + "absolute the product does not guarantee."
                )
            }
        }
    }

    /// Full Disk Access has no per-folder form. A consent surface that implies otherwise
    /// materially understates what the user is handing over.
    func test_fullDiskAccessDisclosesTheGrantIsOSWide() {
        let frame = SystemPermissionKind.fullDiskAccess.safetyFrame
        let text = (frame.whoWatches + " " + frame.whoDrives).lowercased()
        XCTAssertFalse(
            text.contains("a specific folder macos keeps fenced off"),
            "FDA copy must not imply the grant is scoped to one folder"
        )
        XCTAssertTrue(
            text.contains("all of your protected data") || text.contains("not just the folder"),
            "FDA copy must say the macOS grant is broader than OpenBurnBar's use of it"
        )
    }

    /// The safety frame must add information rather than restate the sales copy, or the
    /// pre-prompt sheet is just the wizard again with a different heading.
    func test_safetyFrameIsNotACopyOfTheExistingCapabilityCopy() {
        for kind in allKinds {
            let frame = kind.safetyFrame
            let existing = [
                kind.onboardingCapabilitySummary,
                kind.heroExplanation,
                kind.displaySubtitle
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            for field in [frame.whoWatches, frame.whereItGoes, frame.whoDrives, frame.ifYouDecline] {
                let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(
                    existing.contains(trimmed),
                    "\(kind) safety frame duplicates existing capability copy verbatim: \(trimmed)"
                )
            }
        }
    }

    /// The two genuinely powerful grants should tell a hesitant user it is fine to
    /// decline. Saying "say no" once is what makes the reassurance elsewhere credible.
    func test_mostPowerfulGrantsInviteDeclining() {
        for kind in [SystemPermissionKind.remoteDesktop, .systemExtension] {
            let text = kind.safetyFrame.ifYouDecline.lowercased()
            XCTAssertTrue(
                text.contains("never need") || text.contains("say no"),
                "\(kind) should make declining an explicitly reasonable choice, got: \(text)"
            )
        }
    }

    /// Revocation instructions are only useful if they name where to go.
    func test_revokeInstructionsNameASettingsLocation() {
        for kind in allKinds {
            let text = kind.safetyFrame.howToRevoke
            XCTAssertTrue(
                text.contains("System Settings"),
                "\(kind).howToRevoke should name System Settings, got: \(text)"
            )
        }
    }
}
