// SPDX-License-Identifier: AGPL-3.0-only
//
// Windows-port WPD-0007: dynamic library entry that re-exports the OpenBurnBarCore
// C-ABI surface for P/Invoke consumers. The dynamic-library target must own the
// exported symbols so incremental and whole-module builds cannot dead-strip them.

@_exported import OpenBurnBarCore

@_cdecl("obb_parse_cli_stdout")
public func openBurnBarCAbiParseCLIStdout(
    stdout: UnsafePointer<CChar>?,
    provider: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    obb_parse_cli_stdout(stdout: stdout, provider: provider)
}

@_cdecl("obb_scan_usage")
public func openBurnBarCAbiScanUsage(
    requestJSON: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    obb_scan_usage(requestJSON: requestJSON)
}

@_cdecl("obb_string_free")
public func openBurnBarCAbiStringFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    obb_string_free(pointer)
}
