# Packet A2: OpenBurnBarKernelModels — dead deletions + internalizations

STATE: EXECUTED on core-decomp2/a2-kernelmodels — **5 types DELETED, 2 types
INTERNALIZED, 26 candidates reclassified ALIVE/keep-public** (compiler-proven).
Baseline ratcheted 438t/2543m → 431t/2521m. See "Converged reality" below.
LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a1-kernelplatform (PR base)
BASELINE-TOUCHING: budgets/public-api-baseline.json (--update committed here; no
sibling A-packet touches KernelModels, so the shrink lands in-packet per A0-README)

Read A0-README.md shared rules FIRST.

## Scope

### dead (27) — delete after re-verification
AssistantQuickPromptID, AssistantRuntimeOption, BurnBarCatalogVisibility,
BurnBarProviderCapability, CLITerminalSessionPipeObserver, CloudDeviceTrustState,
FusionUsageParentPrefix, HarnessRuntimeBinding, HarnessRuntimeDeliveryMode,
HarnessRuntimeRecoveryStrategy, LedgerReadFailureHandler, MemoryTrustTier,
ModelCapabilitySourceRef, OpenBurnBarErrorDomain, ProviderAccountHealthEvidence,
ProviderModelBenchmarkFreshness, ProviderModelBenchmarkSource,
ProviderQuotaUtilizationFactor, ProviderRoutingDecision,
ProviderRoutingModelCompatibility, ProviderRoutingRuntimeSignal,
ProviderRoutingSkip, ProviderRoutingSkipReason, ProviderRuntimeHealthSignal,
ResolvedProviderEndpoint, SyncWatermarkCollection, TierGrant

CAUTION: several are Codable provider-catalog types — check for string-keyed
decoding (catalog JSON) and the Windows/Linux ports' mirrored decoders before
deleting. ProviderRouting* smells like a designed-but-unwired subsystem:
confirm with Alberto's program notes if in doubt, else delete (git preserves).

### own-module-only (6) — make internal
AskAssistantIntent, BurnBarCatalogError, DispatchTransport, InstallSource,
ProviderEndpointBillingLane, ProviderEndpointProfile

### test-only (18) — DO NOT TOUCH (WAIT-FOR-WS-B, packet A9)

## Method
Dead deletions first (own commit), then internalizations (own commit).
Full V-list. Converged-reality section into this card.

## Converged reality (executed on core-decomp2/a2-kernelmodels)

**Compiler is the oracle.** Every one of the 33 candidates (27 dead + 6
own-module-only) has ZERO word-boundary references outside its declaring `.swift`
file anywhere in the repo (Sources, Tests, AgentLens, OpenBurnBarMobile,
OpenBurnBarDaemon, apps, md/json/ts/plist) — the classifier's grep is honest.
But the classifier greps the TYPE NAME cross-module; it cannot see a type reached
only through **member access on a live sibling** or a **function's inferred /
explicit return type** (the documented A9/A1 blind spot). 26 of the 33 are exactly
that: structural sub-types (property / init-param / return types) of surviving
PUBLIC API, so they must stay public. Only 7 are genuinely severable.

### DELETED (5) — a self-contained dead cluster, `ProviderRuntimeFailoverTypes.swift`
`HarnessRuntimeBinding`, `HarnessRuntimeDeliveryMode`, `HarnessRuntimeRecoveryStrategy`,
`ProviderAccountHealthEvidence`, `ProviderRuntimeHealthSignal`. These form a closed
designed-but-unwired "harness runtime failover" subsystem: the two structs are
referenced by NOTHING (not even tests), and the three enums are consumed ONLY by
those two structs. The sibling test-only types in the same file
(`ProviderRuntimeAccount`, `ModelCapabilityClass`, `ProviderRuntimeFailoverPolicy`)
do not touch them. Deletion is safe; git preserves. (Matches the card's
"designed-but-unwired subsystem, else delete" guidance — this is the Harness*
family; the *ProviderRouting** family is NOT deletable, see below.)

### INTERNALIZED (2)
- `BurnBarCatalogError` (`OpenBurnBarCatalog.swift`) — only `throw`n in-module,
  no typed-throws signature exposes it. `public enum` + `public var
  errorDescription` → `internal`.
- `FusionUsageParentPrefix` (`TokenUsage.swift`) — namespace enum whose `.value`
  static is used only inside a live method BODY (not a signature); the
  `FusionUsageRow` twin in KernelContracts keeps its own byte-identical alias, so
  this is a duplicated constant, not a cross-module reference. `public enum` +
  `public static let value` → `internal`.

### RECLASSIFIED ALIVE — keep public (26); classifier over-counted
**Dead-list types that are structural members of LIVE cross-module public API:**
`AssistantQuickPromptID` (→`AssistantQuickPrompt.id`),
`BurnBarCatalogVisibility`/`BurnBarProviderCapability` (→catalog struct props +
`container.decode(_:)`), `CLITerminalSessionPipeObserver` (→return type of
`CLITerminalSessionSupervisor` public method), `CloudDeviceTrustState`
(→`CloudDevice.trustState`), `LedgerReadFailureHandler` (→`BudgetGate` public
init param), `MemoryTrustTier` (→`MemorySnippet.trustTier`),
`ModelCapabilitySourceRef` (→public `.sourceRefs`), `OpenBurnBarErrorDomain`
(→public error `.domain`), `ProviderModelBenchmarkFreshness`/`…Source`
(→`ProviderModelBenchmarkStatus`/`…Snapshot` props),
`ProviderQuotaUtilizationFactor` (→`ProviderQuotaUtilizationComparison.factor`),
`ProviderRoutingDecision` (→return of public `ProviderRoutingPolicy.decide()`),
`ProviderRoutingModelCompatibility`/`…RuntimeSignal`/`…Skip`/`…SkipReason` (→live
`ProviderRoutingCandidate`/`…Decision`/`…Event` props+methods),
`ResolvedProviderEndpoint` (→return of public resolver), `SyncWatermarkCollection`
(→`SyncWatermark.collectionKind`), `TierGrant` (→`.cloud/.pro/.ultra` props of a
live sibling struct).

**Dead-list App-Intent pair — reflection-registered, keep public (judgment call):**
`AssistantRuntimeOption` (`AppEnum`) — member of `AskAssistantIntent`.

**own-module-only list that is actually public-API-reachable:**
- `AskAssistantIntent` (`AppIntent`, `openAppWhenRun=true`) — the widget "Ask
  Hermes / Ask Pi" chips fire it; App Intents are discovered by OS **metadata
  extraction**, never by a Swift symbol reference (no `AppShortcutsProvider` in
  repo). Internalizing would strip it from the extracted metadata and silently
  break the widget/Shortcuts action. Keep public. (Same for its `AssistantRuntimeOption`.)
- `DispatchTransport`, `InstallSource` — public stored props of `AgentIdentity`
  (heavily cross-module: UI, Mobile, tests). Keep public.
- `ProviderEndpointProfile`, `ProviderEndpointBillingLane` — consumed by the
  public members of `ResolvedProviderEndpoint` (`init(profile:)`, `.billingLane`)
  AND returned by the public `ProviderEndpointProfileRegistry` surface (called by
  AgentLens / Daemon / Quota adapters). Keep public.

### Compiler proof
`swift build` on the Core package (5 deletions + 2 internalizations applied) =
**green, 0 errors**. `swift test` = **2016 test cases, 0 failures** (identical to
baseline). `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build` on Core =
green. `OpenBurnBarDaemon swift build` = green. Zero references to any of the 7
changed symbols exist in AgentLens/Mobile/Daemon/other-Core-modules, so the
apps-representative path is unaffected by construction.
`scripts/debt/check-public-api-budget.sh --check` PASSES at the new floor
(431t/2521m). Baseline diff touches ONLY the KernelModels entry.

Net: `budgets/public-api-baseline.json` ratchets `OpenBurnBarKernelModels`
438t/2543m → 431t/2521m (−5 deleted −2 internalized types; −22 members).
