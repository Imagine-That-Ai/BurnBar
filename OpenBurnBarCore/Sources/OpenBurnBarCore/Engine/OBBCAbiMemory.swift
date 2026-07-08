// SPDX-License-Identifier: AGPL-3.0-only
//
// Windows-port WPD-0007: C-ABI heap helpers for P/Invoke callers (C# DllImport).
// Returned strings are UTF-8 NUL-terminated buffers allocated with malloc; free via
// `obb_string_free`.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

enum OBBCAbiMemory {
    static func duplicateCString(_ string: String) -> UnsafeMutablePointer<CChar>? {
        string.withCString { cString in
            guard let dup = strdup(cString) else { return nil }
            return dup
        }
    }
}

@_cdecl("obb_string_free")
public func obb_string_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    guard let ptr else { return }
    free(ptr)
}
