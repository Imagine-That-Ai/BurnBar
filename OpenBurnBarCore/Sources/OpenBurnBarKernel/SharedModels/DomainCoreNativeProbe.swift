import Foundation

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI

@_silgen_name("uniffi_openburnbar_domain_ffi_fn_func_domain_core_abi_version")
private func rawDomainCoreABIVersion(_ status: UnsafeMutableRawPointer) -> UInt32
#endif

public enum DomainCoreNativeProbe {
    public static func abiVersion() -> UInt32? {
        #if canImport(OpenBurnBarDomainCoreFFI)
        // RustCallStatus is 32 bytes/alignment 8 on every supported Apple target.
        // Calling the raw C export avoids generated UniFFI checksum initialization,
        // which intentionally traps when an incompatible artifact is present.
        var statusStorage = [UInt64](repeating: 0, count: 4)
        let result = statusStorage.withUnsafeMutableBytes { bytes -> (UInt32, Int8) in
            guard let baseAddress = bytes.baseAddress else { return (0, -1) }
            let version = rawDomainCoreABIVersion(baseAddress)
            return (version, baseAddress.load(as: Int8.self))
        }
        return result.1 == 0 ? result.0 : nil
        #else
        nil
        #endif
    }
}
