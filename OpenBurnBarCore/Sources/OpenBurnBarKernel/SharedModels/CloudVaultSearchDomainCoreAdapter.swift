// Legacy-deletion tracking shim: the wave 3.2 Kernel domain split moved the
// implementation to
// OpenBurnBarVaultModels/CloudVaultSearchDomainCoreAdapter.swift. The
// domain-core legacy-deletion ledger pins this path and the
// OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE literal until the
// cloudvault.search row reaches legacy_deleted, so this file re-exports the
// moved module to keep the pinned path live.
@_exported import OpenBurnBarVaultModels
