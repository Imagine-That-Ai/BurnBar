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
