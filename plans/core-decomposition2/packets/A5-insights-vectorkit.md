# Packet A5: OpenBurnBarInsights + OpenBurnBarVectorKit — curation

STATE: QUEUED  LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
BASELINE-TOUCHING: budgets/public-api-baseline.json (see A0-README etiquette)

Read A0-README.md shared rules FIRST.

## Scope

### OpenBurnBarInsights — dead (10)
CachedCanvas, DueCadences, HostedFallbackProvider, InsightAnalysisStreamEvent,
InsightStreamingModelGateway, KeyProvider, LLMAuthor, PiInsightAdapter,
PromptIntent, URLProvider

### OpenBurnBarInsights — own-module-only (6)
AnthropicInsightAdapter, InsightAnalysisModelPrompt, InsightInvestigationBudget,
InsightProviderFamilyEntry, InsightToolDefinitions, OpenAIInsightAdapter
CAUTION: the *InsightAdapter family is likely instantiated via a registry/
factory inside the module — internalizing is safe, deleting is not; the
adapters marked DEAD (PiInsightAdapter) still need the registry re-check.

### OpenBurnBarInsights — test-only (18) — DO NOT TOUCH (WAIT-FOR-WS-B, A9)

### OpenBurnBarVectorKit — dead (8)
BurnBarFTSField, BurnBarLookupQueryHeuristics, BurnBarSearchAnalysisIntent,
BurnBarSearchQueryMode, BurnBarSearchRankingIntent, BurnBarVectorIndexCandidate,
ExpansionResult, ExpansionType

### OpenBurnBarVectorKit — own-module-only (2)
BurnBarPersistentVectorIndexReadableIndex, BurnBarPersistentVectorIndexWritableIndex

### OpenBurnBarVectorKit — test-only (7) — DO NOT TOUCH (WAIT-FOR-WS-B, A9)

## Method
Dead deletions first (per-module commits), then internalizations.
Full V-list. Converged-reality section into this card.
