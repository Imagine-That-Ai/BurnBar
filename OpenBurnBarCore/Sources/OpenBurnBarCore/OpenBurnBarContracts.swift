// OpenBurnBarContracts.swift
//
// This file previously contained all OpenBurnBar daemon/app contract types in a single
// 1385-line monolith. It has been decomposed into domain-specific files under Contracts/:
//
//   Contracts/BurnBarRPCContracts.swift        — RPC plumbing (protocol version, method enum, envelopes)
//   Contracts/BurnBarRunContracts.swift         — Run lifecycle (phase, state machine, CRUD requests)
//   Contracts/BurnBarToolContracts.swift        — Tool definitions, invocations, results, snapshots
//   Contracts/BurnBarApprovalContracts.swift    — Approval request/response, readiness codes
//   Contracts/BurnBarProviderContracts.swift    — Provider settings, credentials, usage, health, catalog
//   Contracts/BurnBarConnectorContracts.swift   — Connector plane + browser tooling
//   Contracts/BurnBarClientContracts.swift      — Client attach/detach/arbitration
//   Contracts/BurnBarEventContracts.swift       — Daemon event envelope
//
// All types remain in the same SPM target (OpenBurnBarCore) so no import changes are needed.
// This file is intentionally empty and can be deleted once the team confirms the split is stable.
