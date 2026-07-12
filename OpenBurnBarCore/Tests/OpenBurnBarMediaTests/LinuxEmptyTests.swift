import XCTest

#if os(Linux)
/// Phase 3 Linux test backfill: compile-gate smoke for this target on Linux.
final class LinuxTargetCompileGateTests: XCTestCase {
    func testLinuxTargetLinks() {
        XCTAssertTrue(true, "Linux target compiles and loads XCTest")
    }

    func testProcessEnvironmentReadable() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment)
    }
}
#else
final class LinuxEmptyTests: XCTestCase {
    func testLinuxPlaceholder() {}
}
#endif
