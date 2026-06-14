#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

@MainActor
final class ComputerUsePanicHaltCoordinatorTests: XCTestCase {
    func testAccessibilityPollHaltsWhenTrustIsRevokedMidSession() {
        let trust = AccessibilityTrustBox(true)
        let haltedSources = PanicSourceRecorder()
        let coordinator = ComputerUsePanicHaltCoordinator(
            accessibilityTrustProvider: { trust.value },
            halt: { source in
                haltedSources.append(source)
            }
        )

        coordinator.install()
        XCTAssertTrue(coordinator.pollAccessibilityTrustNow())
        XCTAssertTrue(haltedSources.values.isEmpty)

        trust.value = false

        XCTAssertFalse(coordinator.pollAccessibilityTrustNow())
        XCTAssertEqual(haltedSources.values, [.accessibilityRevoked])

        coordinator.uninstall()
    }

    func testAccessibilityPollDoesNotHaltWhenSessionStartsAlreadyUntrusted() {
        let haltedSources = PanicSourceRecorder()
        let coordinator = ComputerUsePanicHaltCoordinator(
            accessibilityTrustProvider: { false },
            halt: { source in
                haltedSources.append(source)
            }
        )

        coordinator.install()
        XCTAssertFalse(coordinator.pollAccessibilityTrustNow())
        XCTAssertTrue(haltedSources.values.isEmpty)

        coordinator.uninstall()
    }
}

private final class AccessibilityTrustBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        self.storage = value
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class PanicSourceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ComputerUsePanicSource] = []

    var values: [ComputerUsePanicSource] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ source: ComputerUsePanicSource) {
        lock.lock()
        storage.append(source)
        lock.unlock()
    }
}
#endif
