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

## Converged reality (compiler-verified)

The classifier heavily OVER-counted "dead" for this module pair: its "dead"
verdict is "no word-boundary ref OUTSIDE the declaring FILE", which misses
types that flow through OTHER public signatures in the same file (or through a
public sibling/enclosing type). The compiler is the oracle; grep re-verify +
whole-package build converged as follows.

### Net result
- Internalized (public -> internal): **7** types
  - Insights own-module-only (5): AnthropicInsightAdapter, OpenAIInsightAdapter,
    InsightAnalysisModelPrompt (+ its members; sibling InsightAnalysisModelDecoder
    left public), InsightInvestigationBudget, InsightToolDefinitions (+ nested Tool).
  - Insights "dead" that was really own-module (1): PromptIntent (+ its accessors
    classifyPromptIntent / answerEyebrow — called only via `Self.` in-module).
  - VectorKit "dead" that was really own-module (1): BurnBarLookupQueryHeuristics
    (static-only namespace, never in a public signature).
- Deleted (truly dead, 0 swift refs anywhere): **1** — PiInsightAdapter
  (NOT registry-wired: InsightProviderGatewayRegistry constructs Ollama/OpenAI/
  Anthropic/OpenAICompatible only; the `.pi` family enum + "pi" providerKey string
  are separate LIVE types, not this adapter).
- Reverted / reclassified ALIVE (classifier over-count — transitively cross-module
  via public API): **15**
  - Insights "dead" kept public (8): CachedCanvas (InsightCache.lookup/store public,
    InsightCache cross-module), DueCadences (CadenceScheduler.due public), KeyProvider
    / URLProvider / HostedFallbackProvider (params of public registerDefaultSwiftGateways,
    called by AgentLens + Mobile), InsightAnalysisStreamEvent / InsightStreamingModelGateway
    (public HermesInsightAdapter conforms + streams the event; HermesInsightAdapter
    cross-module), LLMAuthor (param of public VerdictComposer.init, used by AgentLens).
  - Insights own-module-only reverted (1): InsightProviderFamilyEntry — COMPILER-CAUGHT:
    it is the result/param type of public methods on InsightProviderFamilyCatalog
    (a TEST-ONLY type this packet must NOT touch), so it must stay public.
  - VectorKit "dead" kept public (5): BurnBarFTSField (public BurnBarFieldBoostConfig.boost
    / QueryToken.fieldHint / fieldBoosted), BurnBarSearchQueryMode / BurnBarSearchRankingIntent
    / BurnBarSearchAnalysisIntent (stored props of public BurnBarSearchPlan, cross-module),
    BurnBarVectorIndexCandidate (returned by public candidates(for:limit:), called by AgentLens),
    ExpansionResult / ExpansionType (returned/used by public BurnBarQueryExpander API).
    [ExpansionResult/ExpansionType were never edited: pre-analysis proved cross-module reach.]
  - VectorKit own-module-only reverted (2): BurnBarPersistentVectorIndexReadableIndex /
    WritableIndex — return types of makeReadable/makeWritable, requirements of the PUBLIC
    cross-module protocol BurnBarPersistentVectorIndexBackend (AgentLens + Daemon).
    [Never edited: pre-analysis proved they flow through a public protocol requirement.]

### Baseline ratchet (this PR)
- OpenBurnBarInsights: 269t/1289m -> **261t/1223m**
- OpenBurnBarVectorKit: 49t/244m -> **48t/243m**
(only these two module entries changed; whole test suite green, same 2003 cases.)
