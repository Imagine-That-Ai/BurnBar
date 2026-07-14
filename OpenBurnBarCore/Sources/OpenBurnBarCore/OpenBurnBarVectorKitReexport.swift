// SPDX-License-Identifier: AGPL-3.0-only
//
// Core-decomposition S0 (docs/CORE_DECOMPOSITION_PROGRAM.md). Pattern = KernelReexport.swift.
//
// Re-export the OpenBurnBarVectorKit decomposition target so every existing
// `import OpenBurnBarCore` consumer keeps compiling with zero call-site changes
// once its move packet lands. The target is populated by `git mv`; the shim is
// created here (S0) so the seam is invisible from the first packet onward. Move
// packets NEVER edit this file.
@_exported import OpenBurnBarVectorKit
