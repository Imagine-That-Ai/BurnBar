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
