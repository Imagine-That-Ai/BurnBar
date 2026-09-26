// Legacy-deletion tracking shim: the wave 3.2 Kernel domain split moved the
// implementation to OpenBurnBarHermesModels/HermesRatchetLegacyCrypto.swift.
// The domain-core legacy-deletion ledger pins this path until the
// hermes.ratchet_transforms row reaches legacy_deleted, so this file
// re-exports the moved module to keep the pinned path live.
@_exported import OpenBurnBarHermesModels
