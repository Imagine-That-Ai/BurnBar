// Legacy-deletion tracking shim: the wave 3.2 Kernel domain split moved the
// implementation to OpenBurnBarVaultModels/CloudVaultLegacyDocumentRewrap.swift.
// The domain-core legacy-deletion ledger pins this path until the
// cloudvault.document_rewrap row reaches legacy_deleted, so this file
// re-exports the moved module to keep the pinned path live.
@_exported import OpenBurnBarVaultModels
