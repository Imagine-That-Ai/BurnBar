// SPDX-License-Identifier: AGPL-3.0-only
//
// Windows-port WPD-0007: dynamic library entry that re-exports the OpenBurnBarCore
// C-ABI surface (`obb_parse_cli_stdout`, `obb_string_free`) for P/Invoke consumers.

@_exported import OpenBurnBarCore