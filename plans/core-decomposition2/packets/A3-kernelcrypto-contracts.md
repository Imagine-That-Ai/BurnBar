# Packet A3: OpenBurnBarKernelCrypto + OpenBurnBarKernelContracts — curation

STATE: QUEUED  LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
BASELINE-TOUCHING: budgets/public-api-baseline.json (see A0-README etiquette)

Read A0-README.md shared rules FIRST.

## Scope

### OpenBurnBarKernelCrypto — dead (4)
CLIAgentSessionSourceKind, EscrowAuditEventType,
HermesRelayOpenedAuthenticatedRequest, RoamingModelEquivalenceAction
CAUTION: Escrow*/HermesRelay* are wire/security types — verify against the
daemon, functions/ (TS), and the RPC canon (tools/ipc) before deleting.
Security-adjacent deletions get an explicit line in the PR body.

### OpenBurnBarKernelCrypto — own-module-only (1)
CloudVaultJSON

### OpenBurnBarKernelContracts — dead (20)
BurnBarApprovalPolicy, BurnBarAuthBootstrapRequest, BurnBarAuthBootstrapResponse,
BurnBarDaemonEvent, BurnBarDaemonEventKind, BurnBarPlanStepStatus,
BurnBarProjectionStatusKind, BurnBarProjectSelector,
BurnBarProtocolHandshakeRequest, BurnBarProtocolHandshakeResponse,
BurnBarRecoveryAction, BurnBarRunCreateMetadataKey, BurnBarRunStateMachineError,
BurnBarRunSubscribeRequest, BurnBarSchedulerPhase, BurnBarToolDefinition,
BurnBarWorkspaceCapability, CLIAgentSessionActionStatusPresentation,
ComputerUseSessionDocSnapshot, TraceContext
CAUTION: Contracts types are WIRE CONTRACTS by design — many are
Request/Response pairs for RPCs that may be implemented on the TS/Rust side.
Cross-check tools/ipc/generate-burnbarrpc-canon.mjs's canon and functions/
before deleting; run `canon --check` in the V-list. Expect a high
reclassify-to-alive rate here; that is a fine outcome.

### OpenBurnBarKernelContracts — own-module-only (2)
BurnBarControllerNextActionBucket, BurnBarReplayStatus

### test-only — DO NOT TOUCH (Crypto 13, Contracts 13; WAIT-FOR-WS-B, packet A9)

## Method
Dead deletions first (per-module commits), then internalizations.
Full V-list. Converged-reality section into this card.
