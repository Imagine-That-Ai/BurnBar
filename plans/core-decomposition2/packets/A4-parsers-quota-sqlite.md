# Packet A4: LogParsers + Quota + SQLiteReader — curation

STATE: QUEUED  LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
BASELINE-TOUCHING: budgets/public-api-baseline.json (see A0-README etiquette)

Read A0-README.md shared rules FIRST.

## Scope

### OpenBurnBarLogParsers — dead (4)
DecodedProjectPath, FallbackEstimator, HostOS, ResolvedLogSource
CAUTION: parser types have Windows/Linux parity mirrors
(OpenBurnBarWindowsParserPathParity, OpenBurnBarG2ParserParity targets) —
re-verify there before deleting.

### OpenBurnBarLogParsers — own-module-only (1)
ParserDiagnostics

### OpenBurnBarQuota — dead (7)
CursorIndividualUsage, CursorLegacyRequestUsage, CursorLegacyUsageResponse,
CursorOnDemandUsage, CursorPlanUsage, RateLimitsResult, WarpCredits
CAUTION: Cursor* are Decodable mirrors of a third-party API response — if the
parent envelope decodes them via nested Codable, they are NOT dead (the grep
sees the nested-property type names, so a true dead verdict means even the
parent stopped referencing them — still, re-verify the decode chain).

### OpenBurnBarQuota — own-module-only (12)
CodexRateLimitEvent, CodexRateLimitScanResult, CodexRateLimitWindow,
CodexRolloutEnvelope, CodexRolloutFileCacheEntry, CodexRolloutFileSignature,
FactoryAuthResponseEnvelope, FactorySessionCredentialEnvelope,
FactoryUsageEnvelope, NoOpCLIExecutor, QuotaJWTPayload, QuotaSHA256

### OpenBurnBarQuota — test-only (4) — DO NOT TOUCH (WAIT-FOR-WS-B, packet A9)

### OpenBurnBarSQLiteReader — own-module-only (2)
SQLiteArgument, SQLiteError
CAUTION: tiny module consumed by the daemon; confirm the daemon builds after
internalization (it is in the standard V-list anyway).

## Method
Dead deletions first (per-module commits), then internalizations.
Full V-list. Converged-reality section into this card.

## CONVERGED REALITY (executed on core-decomp2/a4, compiler-proven)

The classifier's "dead"/"own-module-only" verdicts mean only "the type NAME has no
word-boundary reference outside its declaring file(s)". The compiler is the oracle:
a type reached through a public signature (protocol requirement, public property of a
cross-module type, public-init default-argument, public method return) is transitively
public even when its bare name never appears cross-module. That over-count landed on a
large fraction of this card. Empirically confirmed by temporarily internalizing
`SQLiteArgument` → `error: method cannot be declared public because its parameter uses an
internal type` (SQLiteConnection.query/execute), then reverting.

### DELETED (genuinely dead — zero refs beyond the decl line) — 2
- `CursorLegacyUsageResponse`, `CursorLegacyRequestUsage` (Quota / ProviderQuotaModels.swift):
  never decoded/instantiated; the parent envelope stopped referencing them (CAUTION cleared).

### INTERNALIZED public → internal (own-module-only, not in any public signature) — 8 types
- LogParsers: `ParserDiagnostics` (+ its nested `Event` struct) — the no-op diagnostic seam.
- Quota: `CodexRolloutEnvelope`; `FactorySessionCredentialEnvelope`,
  `FactoryAuthResponseEnvelope`, `FactoryUsageEnvelope` (returned only by `private`
  FactoryQuotaAdapter methods; members were already internal); `QuotaJWTPayload`,
  `QuotaSHA256` (internal static-func utilities).
- SQLiteReader: `SQLiteError` (only ever thrown/`description`-read; throwing does not leak
  into a public signature; no cross-module `catch as SQLiteError`).

### KEPT PUBLIC — classifier over-counted (reverted / not touched) — 15 types
- LogParsers "dead": `DecodedProjectPath` (return of public `ClaudeCodeProjectPathCodec.decode`,
  used by the WindowsParserPathParity target + AgentLens codec fixtures),
  `FallbackEstimator` (type of public `TokenExtractionUtility.fallbackEstimator`, assigned by
  AgentLens UsageAggregator), `HostOS` (param/return of public `LogPathPlatform.current` /
  `resolveLogDirectory(os:)`, passed `.posix`/`.windows` by the G2 + Windows parity targets),
  `ResolvedLogSource` (return of public `AgentProviderLogDiscovery.resolveLogSource`, consumed
  by the Linux CoreFoundation test target).
- Quota "dead": `CursorIndividualUsage`, `CursorPlanUsage`, `CursorOnDemandUsage` (public
  stored properties of cross-module `CursorUsageSummary`); `RateLimitsResult` (return of public
  `ClaudeOAuthUsageFetcher.fetchRateLimits`, consumed by AgentLensTests); `WarpCredits` (return
  of public `WarpAPIFetcher.fetchCredits` — kept public to preserve the fetcher contract rather
  than demote the method).
- Quota "own-module-only": `CodexRateLimitEvent`, `CodexRateLimitWindow`,
  `CodexRolloutFileSignature`, `CodexRolloutFileCacheEntry` (all reachable via the public stored
  properties of cross-module `CodexRolloutScanCache`, which AgentLens decodes/persists);
  `CodexRateLimitScanResult` (return of public `CodexRolloutScanner.scanCodexRateLimitEvents`);
  `NoOpCLIExecutor` (default-arg `NoOpCLIExecutor()` in the public inits of
  `ClaudeOAuthUsageFetcher` + `ProviderQuotaAdapter`).
- SQLiteReader: `SQLiteArgument` (parameter type in the public `SQLiteReading` protocol
  requirement `query(_:arguments:)`).

### RATCHET (budgets/public-api-baseline.json, this PR)
- OpenBurnBarLogParsers 44t/189m → 42t/184m
- OpenBurnBarQuota 93t/201m → 85t/199m
- OpenBurnBarSQLiteReader 6t/19m → 5t/15m

Net: 10 symbols changed (2 deleted + 8 internalized); 15 reverted-to/kept-public. The 4
Quota test-only types (FactorySessionLane, JSONLTokenWindows, NoOpQuotaLogger, NoOpSecretStore)
remain untouched — WAIT-FOR-WS-B, packet A9.
