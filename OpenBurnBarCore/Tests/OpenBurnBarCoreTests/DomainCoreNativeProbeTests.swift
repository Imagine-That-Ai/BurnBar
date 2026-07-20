import Foundation
import XCTest
#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif
@testable import OpenBurnBarCore

final class DomainCoreNativeProbeTests: XCTestCase {
    // The probe is the availability gate every native Pensieve/CloudVault path
    // consults before touching the FFI. Its contracts:
    //   1. It must report a non-nil abi version when the healthy native core is
    //      linked (the `guard DomainCoreNativeProbe.abiVersion() == 3` sites in
    //      PensieveVectorCloak depend on this).
    //   2. It must agree with the high-level UniFFI binding so the raw
    //      RustCallStatus shortcut and the generated wrapper never disagree.
    //   3. Without the FFI it must report nil (fail-closed), never crash or
    //      return a sentinel.

    #if canImport(OpenBurnBarDomainCoreFFI)
    func test_abiVersionReportsNativeCoreVersionWhenFFIPresent() {
        let version = DomainCoreNativeProbe.abiVersion()
        XCTAssertNotNil(version, "probe must report an abi version when the FFI is linked")
        // The Pensieve native guard hard-codes == 3; a probe that returns a
        // different value would silently disable every native vector path.
        XCTAssertEqual(version, 3, "probe abi version must match the Pensieve guard contract")
    }

    func test_probeAgreesWithHighLevelUniFFIBinding() {
        // The raw C-export shortcut exists to bypass UniFFI checksum
        // initialization (which traps on incompatible artifacts). If the two
        // ever disagree, either the shortcut is reading the status storage
        // wrong or the binding is masking an error — both are defects.
        let probed = DomainCoreNativeProbe.abiVersion()
        let bound = OpenBurnBarDomainCoreFFI.domainCoreAbiVersion()
        XCTAssertEqual(probed, bound, "raw probe and UniFFI binding must report the same abi version")
    }
    #else
    func test_abiVersionFailsClosedWhenFFIAbsent() {
        // Clean-checkout contract: no FFI ⇒ nil, not a crash or zero. This is
        // what keeps PensieveVectorCloak's native guards throwing
        // nativeUnavailable instead of trapping on a missing symbol.
        XCTAssertNil(DomainCoreNativeProbe.abiVersion())
    }
    #endif
}
