# Packet A2: OpenBurnBarKernelModels — dead deletions + internalizations

STATE: QUEUED  LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
BASELINE-TOUCHING: budgets/public-api-baseline.json (see A0-README etiquette)

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
