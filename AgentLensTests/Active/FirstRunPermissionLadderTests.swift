#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

/// The regression fence for "no macOS dialog before BurnBar has explained itself".
///
/// This invariant is easy to state and easy to break: it only takes one new settings
/// row calling `CGRequestScreenCaptureAccess()` directly. Asserting it here means the
/// rule survives without anyone having to remember it, and without needing a clean Mac
/// to notice it was broken.
@MainActor
final class FirstRunPermissionLadderTests: XCTestCase {

    /// Records what the ladder did, in order, so tests can assert on sequence rather
    /// than only on final state.
    private final class Recorder {
        enum Event: Equatable {
            case explained(SystemPermissionKind)
            case prompted(SystemPermissionKind)
        }
        var events: [Event] = []
    }

    private func makeLadder(
        recorder: Recorder,
        explainerAnswer: Bool = true,
        status: SystemPermissionStatus? = .needsAccess
    ) -> FirstRunPermissionLadder {
        let ladder = FirstRunPermissionLadder(
            prompter: { kind, _ in recorder.events.append(.prompted(kind)) },
            statusReader: { _, _ in status }
        )
        ladder.explainer = { kind, _ in
            recorder.events.append(.explained(kind))
            return explainerAnswer
        }
        return ladder
    }

    func test_explanationAlwaysPrecedesTheOSPrompt() async {
        let recorder = Recorder()
        let ladder = makeLadder(recorder: recorder)

        let didPrompt = await ladder.request(.screenRecording)

        XCTAssertTrue(didPrompt)
        XCTAssertEqual(
            recorder.events,
            [.explained(.screenRecording), .prompted(.screenRecording)],
            "BurnBar must speak before macOS does"
        )
    }

    func test_decliningTheExplanationNeverReachesTheOSPrompt() async {
        let recorder = Recorder()
        let ladder = makeLadder(recorder: recorder, explainerAnswer: false)

        let didPrompt = await ladder.request(.accessibility)

        XCTAssertFalse(didPrompt)
        XCTAssertEqual(recorder.events, [.explained(.accessibility)])
        XCTAssertFalse(
            recorder.events.contains(.prompted(.accessibility)),
            "Saying 'Not now' must not hand the user to macOS anyway"
        )
    }

    /// An unwired explainer must fail closed. Degrading to "just show the OS dialog"
    /// would silently restore precisely the behaviour this type exists to remove.
    func test_missingExplainerFailsClosedRatherThanPromptingUnannounced() async {
        let recorder = Recorder()
        let ladder = FirstRunPermissionLadder(
            prompter: { kind, _ in recorder.events.append(.prompted(kind)) },
            statusReader: { _, _ in .needsAccess }
        )
        // explainer deliberately left nil

        let didPrompt = await ladder.request(.screenRecording)

        XCTAssertFalse(didPrompt)
        XCTAssertTrue(recorder.events.isEmpty, "No explainer must mean no prompt, not an unannounced prompt")
    }

    func test_alreadyGrantedKindNeitherExplainsNorPrompts() async {
        let recorder = Recorder()
        let ladder = makeLadder(recorder: recorder, status: .granted)

        let didPrompt = await ladder.request(.microphone)

        XCTAssertFalse(didPrompt)
        XCTAssertTrue(recorder.events.isEmpty, "A granted permission should be left alone entirely")
    }

    /// Explaining once per kind is the point; nagging is not.
    func test_secondRequestSkipsTheExplanationButStillPrompts() async {
        let recorder = Recorder()
        let ladder = makeLadder(recorder: recorder)

        _ = await ladder.request(.screenRecording)
        _ = await ladder.request(.screenRecording)

        XCTAssertEqual(
            recorder.events,
            [.explained(.screenRecording), .prompted(.screenRecording), .prompted(.screenRecording)]
        )
    }

    /// Automation is per-target-app, so each app must get its own explanation.
    func test_automationExplainsPerTargetApp() async {
        let recorder = Recorder()
        let ladder = makeLadder(recorder: recorder)

        _ = await ladder.request(.automation, bundleId: "com.apple.Safari")
        _ = await ladder.request(.automation, bundleId: "com.google.Chrome")

        XCTAssertEqual(
            recorder.events,
            [
                .explained(.automation), .prompted(.automation),
                .explained(.automation), .prompted(.automation)
            ],
            "Allowing one app is not consent for the next one"
        )
    }

    func test_everyKindRoutesThroughAnExplanation() async {
        for kind in SystemPermissionKind.allCases {
            let recorder = Recorder()
            let ladder = makeLadder(recorder: recorder)

            _ = await ladder.request(kind, bundleId: kind == .automation ? "com.apple.Safari" : nil)

            XCTAssertEqual(
                recorder.events.first,
                .explained(kind),
                "\(kind) reached macOS without BurnBar explaining first"
            )
        }
    }
}
#endif
