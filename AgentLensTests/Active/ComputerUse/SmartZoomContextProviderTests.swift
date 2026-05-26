#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class SmartZoomContextResolverTests: XCTestCase {
    private let display = SmartZoomDisplayBounds(
        displayId: "display-1",
        originX: 0,
        originY: 0,
        width: 1920,
        height: 1080
    )

    func testReturnsNilWhenUserSessionLocked() {
        let context = SmartZoomContextResolver.resolve(
            SmartZoomSampleInputs(
                focusedElement: SmartZoomElementSnapshot(
                    role: "AXTextField",
                    subrole: nil,
                    frame: CGRect(x: 100, y: 100, width: 200, height: 30)
                ),
                cursor: CGPoint(x: 500, y: 500),
                displays: [display],
                isUserSessionLocked: true
            )
        )
        XCTAssertNil(context)
    }

    func testPrefersFocusedElementForTextLikeRoles() throws {
        let elementFrame = CGRect(x: 192, y: 432, width: 480, height: 60)
        let inputs = SmartZoomSampleInputs(
            focusedElement: SmartZoomElementSnapshot(
                role: "AXTextField",
                subrole: nil,
                frame: elementFrame
            ),
            focusedWindow: SmartZoomWindowSnapshot(
                appName: "Code",
                bundleId: "com.microsoft.VSCode",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ),
            cursor: CGPoint(x: 800, y: 460),
            displays: [display],
            sampledAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let context = try XCTUnwrap(SmartZoomContextResolver.resolve(inputs))
        XCTAssertEqual(context.targetKind, .focusedElement)
        XCTAssertEqual(context.displayId, "display-1")
        XCTAssertEqual(context.appName, "Code")
        XCTAssertEqual(context.bundleId, "com.microsoft.VSCode")
        XCTAssertNotNil(context.normalizedRect)
        XCTAssertNil(context.normalizedPoint)
    }

    func testTextLikeRectIsPaddedAndNormalized() throws {
        let inputs = SmartZoomSampleInputs(
            focusedElement: SmartZoomElementSnapshot(
                role: "AXTextArea",
                subrole: nil,
                frame: CGRect(x: 0, y: 0, width: 100, height: 20)
            ),
            displays: [display]
        )
        let context = try XCTUnwrap(SmartZoomContextResolver.resolve(inputs))
        let rect = try XCTUnwrap(context.normalizedRect)
        let unpaddedWidth = 100.0 / Double(display.width)
        let unpaddedHeight = 20.0 / Double(display.height)
        XCTAssertGreaterThan(rect.width, unpaddedWidth)
        XCTAssertGreaterThan(rect.height, unpaddedHeight)
        XCTAssertGreaterThanOrEqual(rect.x, 0)
        XCTAssertGreaterThanOrEqual(rect.y, 0)
        XCTAssertLessThanOrEqual(rect.x + rect.width, 1)
        XCTAssertLessThanOrEqual(rect.y + rect.height, 1)
    }

    func testFallsBackToFocusedWindowWhenElementIsNotTextLike() throws {
        let inputs = SmartZoomSampleInputs(
            focusedElement: SmartZoomElementSnapshot(
                role: "AXButton",
                subrole: nil,
                frame: CGRect(x: 100, y: 200, width: 80, height: 24)
            ),
            focusedWindow: SmartZoomWindowSnapshot(
                appName: "Finder",
                bundleId: "com.apple.finder",
                frame: CGRect(x: 200, y: 200, width: 1024, height: 720)
            ),
            displays: [display]
        )
        let context = try XCTUnwrap(SmartZoomContextResolver.resolve(inputs))
        XCTAssertEqual(context.targetKind, .focusedWindow)
        XCTAssertEqual(context.appName, "Finder")
        XCTAssertNotNil(context.normalizedRect)
    }

    func testFallsBackToCursorWhenNoFocusedElementOrWindow() throws {
        let inputs = SmartZoomSampleInputs(
            focusedElement: nil,
            focusedWindow: nil,
            cursor: CGPoint(x: 960, y: 540),
            displays: [display]
        )
        let context = try XCTUnwrap(SmartZoomContextResolver.resolve(inputs))
        XCTAssertEqual(context.targetKind, .cursor)
        let point = try XCTUnwrap(context.normalizedPoint)
        XCTAssertEqual(point.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.001)
        XCTAssertNil(context.normalizedRect)
    }

    func testReturnsNilWhenAccessibilityDeniedAndNoCursor() {
        let context = SmartZoomContextResolver.resolve(
            SmartZoomSampleInputs(
                focusedElement: nil,
                focusedWindow: nil,
                cursor: nil,
                displays: [display],
                isAccessibilityTrusted: false
            )
        )
        XCTAssertNil(context)
    }

    func testIgnoresFocusedElementWhenAccessibilityDenied() throws {
        let inputs = SmartZoomSampleInputs(
            focusedElement: SmartZoomElementSnapshot(
                role: "AXTextField",
                subrole: nil,
                frame: CGRect(x: 100, y: 100, width: 200, height: 30)
            ),
            focusedWindow: nil,
            cursor: CGPoint(x: 100, y: 100),
            displays: [display],
            isAccessibilityTrusted: false
        )
        let context = try XCTUnwrap(SmartZoomContextResolver.resolve(inputs))
        XCTAssertEqual(context.targetKind, .cursor)
    }

    func testExpandRectInflatesByShortAndLongAxisRatios() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let padded = SmartZoomContextResolver.expandRect(
            rect,
            shortAxisRatio: 0.12,
            longAxisRatio: 0.08
        )
        XCTAssertEqual(padded.width, 200 + 2 * 200 * 0.08, accuracy: 0.001)
        XCTAssertEqual(padded.height, 40 + 2 * 40 * 0.12, accuracy: 0.001)
    }

    func testNormalizeRectClampsToZeroOne() {
        let rect = CGRect(x: -100, y: -50, width: 4000, height: 3000)
        let normalized = SmartZoomContextResolver.normalize(rect: rect, in: display)
        XCTAssertEqual(normalized.x, 0)
        XCTAssertEqual(normalized.y, 0)
        XCTAssertLessThanOrEqual(normalized.x + normalized.width, 1)
        XCTAssertLessThanOrEqual(normalized.y + normalized.height, 1)
    }
}

@MainActor
final class SmartZoomContextProviderTests: XCTestCase {
    func testEmitOnceForwardsDecisionToSink() async {
        let display = SmartZoomDisplayBounds(displayId: "d-1", originX: 0, originY: 0, width: 1000, height: 1000)
        let inputs = SmartZoomSampleInputs(
            focusedElement: SmartZoomElementSnapshot(role: "AXTextField", subrole: nil, frame: CGRect(x: 100, y: 100, width: 200, height: 30)),
            focusedWindow: nil,
            cursor: nil,
            displays: [display]
        )
        var emitted: [HermesRealtimeRelayFocusContext] = []
        let provider = SmartZoomContextProvider(
            inputsProvider: { inputs },
            sink: { context in emitted.append(context) },
            clock: TestSmartZoomClock(),
            sampleIntervalSeconds: 0
        )
        await provider.emitOnce()
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.targetKind, .focusedElement)
    }

    func testEmitOnceDedupesIdenticalConsecutiveContexts() async {
        let display = SmartZoomDisplayBounds(displayId: "d-1", originX: 0, originY: 0, width: 1000, height: 1000)
        var emitted: [HermesRealtimeRelayFocusContext] = []
        let provider = SmartZoomContextProvider(
            inputsProvider: {
                SmartZoomSampleInputs(
                    focusedElement: SmartZoomElementSnapshot(role: "AXTextField", subrole: nil, frame: CGRect(x: 100, y: 100, width: 200, height: 30)),
                    displays: [display]
                )
            },
            sink: { context in emitted.append(context) },
            clock: TestSmartZoomClock(),
            sampleIntervalSeconds: 0
        )
        await provider.emitOnce()
        await provider.emitOnce()
        XCTAssertEqual(emitted.count, 1)
    }

    func testEmitOnceProducesNewContextWhenTargetMoves() async {
        let display = SmartZoomDisplayBounds(displayId: "d-1", originX: 0, originY: 0, width: 1000, height: 1000)
        var current: CGRect = CGRect(x: 100, y: 100, width: 200, height: 30)
        var emitted: [HermesRealtimeRelayFocusContext] = []
        let provider = SmartZoomContextProvider(
            inputsProvider: {
                SmartZoomSampleInputs(
                    focusedElement: SmartZoomElementSnapshot(role: "AXTextField", subrole: nil, frame: current),
                    displays: [display]
                )
            },
            sink: { context in emitted.append(context) },
            clock: TestSmartZoomClock(),
            sampleIntervalSeconds: 0
        )
        await provider.emitOnce()
        current = CGRect(x: 700, y: 400, width: 200, height: 30)
        await provider.emitOnce()
        XCTAssertEqual(emitted.count, 2)
        XCTAssertNotEqual(emitted[0].normalizedRect, emitted[1].normalizedRect)
    }
}

private struct TestSmartZoomClock: SmartZoomClock {
    func sleep(for seconds: TimeInterval) async {}
}
#endif
