// SPDX-License-Identifier: AGPL-3.0-only
//
// Phase-2 WS-K (Kernel diet) S0 scaffold — docs/CORE_DECOMPOSITION_PROGRAM.md.
//
// OpenBurnBarKernelModels is the pure-data tier of the OpenBurnBarKernel split.
// It owns the Foundation-only SharedModels (agent/provider/quota/hermes value
// types), Budget/, Entitlements/, Membership/, Metrics/, Errors/, Memory/ (incl.
// MemorySecretPIIGate), the catalog loader + catalog models
// (OpenBurnBarCatalogLoader/OpenBurnBarCatalog/CLIRuntimeModelCatalog/
// WandModelRouter) AND the Resources/ bundle (catalog.json +
// secret-pattern-corpus.json) — this target owns the SwiftPM resource bundle.
// Deps: OpenBurnBarKernelPlatform.
//
// K2 BUNDLE TRANSITION: moving Resources/ here renames the SwiftPM bundle from
// `OpenBurnBarCore_OpenBurnBarKernel.bundle` to
// `OpenBurnBarCore_OpenBurnBarKernelModels.bundle`. The daemon
// (OpenBurnBarDaemonManager.kernelResourceBundleName) + release/smoke scripts
// pin the old name, so K2 stages BOTH names during the transition
// (plans/core-decomposition2/packets/K2-models.md).
//
// At S0 this target holds only this marker. Packet K2 `git mv`s the real files
// in and deletes this marker in the same commit.
enum OpenBurnBarKernelModelsModuleMarker {}
