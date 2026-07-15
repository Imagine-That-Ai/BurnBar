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

## Converged reality (executed on core-decomp2/a3-kernelcrypto-contracts)

Compiler-as-oracle outcome. Whole-package + OpenBurnBarDaemon + Linux-boundary
(Core) builds all green; test count unchanged (6048 XCTest + 31 swift-testing,
0 failures) before and after; `canon --check` rc=0; public-API + baseline-
monotonic (base=a2-kernelmodels) + all other scripts/debt gates + check-no-
suppressions green. Baseline ratchet-down committed in this packet, ONLY the two
owned modules touched (Crypto 88→87t/593→591m, Contracts 435→423t/2129→2081m).

DELETED — 12 (compiler-confirmed zero cross-module use; canon parser stops at
`BurnBarRPCRequestEnvelope` so the 4 RPCContracts stubs are after the boundary
and cannot move the generated canon; verified absent from functions/, tools/ipc,
and the generated canon artifacts):
- KernelContracts: BurnBarToolDefinition + BurnBarApprovalPolicy +
  BurnBarWorkspaceCapability (dead cluster — the two enums are consumed ONLY by
  BurnBarToolDefinition); BurnBarAuthBootstrapRequest/Response;
  BurnBarProtocolHandshakeRequest/Response; BurnBarDaemonEvent +
  BurnBarDaemonEventKind (whole file BurnBarEventContracts.swift removed);
  BurnBarProjectSelector; BurnBarRunSubscribeRequest; ComputerUseSessionDocSnapshot.

INTERNALIZED — 1: CloudVaultJSON (KernelCrypto namespace enum + its two static
JSON coders; used only within KernelCrypto).

RECLASSIFIED ALIVE / kept public — 14 (classifier false-positives: reachable
cross-module via member/enum-case access or via a public container/throwing API,
which the word-boundary-on-type-name rule missed):
- Crypto DEAD(4): CLIAgentSessionSourceKind (CLIAgentSessionRecord.sourceKind —
  Record used in AgentLens/Mobile/tests/KernelContracts), EscrowAuditEventType
  (EscrowAuditEvent.eventType; cases used in OpenBurnBarMobileTests),
  HermesRelayOpenedAuthenticatedRequest (return type of public open(...)),
  RoamingModelEquivalenceAction (RoamingModelEquivalenceOverride.action).
- Contracts DEAD(8): BurnBarPlanStepStatus (BurnBarPlanStep → daemon),
  BurnBarProjectionStatusKind (…Snapshot → daemon+core tests),
  BurnBarRecoveryAction (BurnBarRecoveryDecision → daemon),
  BurnBarRunCreateMetadataKey (metadata extension used across daemon),
  BurnBarRunStateMachineError (thrown by BurnBarRunStateMachine → daemon),
  BurnBarSchedulerPhase (BurnBarDAGSchedulerState → daemon),
  CLIAgentSessionActionStatusPresentation (public var presentation on
  CLIAgentSessionActionStatus → AgentLens/KernelModels/tests), TraceContext
  (TraceContextBridge public statics → AgentLens + daemon).
- Contracts own-module-only(2): BurnBarControllerNextActionBucket (public
  BurnBarControllerNextActionPlanner API + …Snapshot.bucket → daemon consumes the
  planner), BurnBarReplayStatus (BurnBarSimulatorRunSnapshot.status → AgentLens +
  daemon). Neither is safely internalizable — both are the type of a public API
  member on a genuinely cross-module public type.

Tally: 12 deleted / 1 internalized / 14 reclassified-alive of the card's 27.
