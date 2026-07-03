# Parser-output contract + portable fixture corpus

**Contracts:** `VAL-P0-HARNESS-023` (extract the 15 inline parser fixtures to
portable on-disk vectors) · `VAL-P0-HARNESS-024` (parser-output contract format +
Mac golden).

**Status:** macOS-now (LIVE). The byte-identical **Windows** diff is Phase-2 (or
runs when Windows CI is available). This document + the committed Mac golden
deliver the format and the reference vectors today.

---

## Why this exists

The Windows port must reproduce the Mac's usage/quota parsing **byte-for-byte**
(the G2 headline of `docs/WINDOWS_PORT_MASTER_PLAN.md`): given the same provider
session logs, a Windows parser has to emit the same token accounting, session
identity, model, and cost as macOS does today, or usage/quota numbers will
silently diverge across platforms.

Two things blocked that guarantee:

1. **The corpus lived only in Swift.** The 15 parser fixtures were inline
   `static func` string-builders in
   `AgentLensTests/Support/ParserIntegrationTestSupport.swift` — a Windows/C#
   port could not consume them.
2. **The corpus was non-deterministic.** Five builders stamped wall-clock
   `Date()`, so their output changed on every run and could never be captured as
   a stable, portable vector.

This work extracts the corpus to language-neutral on-disk files and defines a
portable, byte-stable projection of parser output that both platforms can diff.

---

## The fixture corpus

Location: `AgentLensTests/Fixtures/ParserContract/` (bundled into the
`OpenBurnBarTests` resources by `project.yml`; a Windows port consumes the
committed repo files directly).

- **15 fixtures**, one per extracted `ParserTestFixtures` builder, spanning the
  four log-bearing providers: Claude Code (8), Factory Droid (2), Codex (3),
  Hermes (2).
- Files are plain, valid `.jsonl` / `.json` — the exact bytes a provider writes
  to disk. Factory Droid's `factoryDroidSessionWithSettings` fixture is three
  files (session JSONL + `settings.json` + `metadata.json`).
- **Every timestamp is frozen.** Builders that used to stamp `Date()` now take an
  injectable `now:` defaulting to `ParserTestFixtures.frozenReferenceDate`
  (`2025-07-01T00:00:00Z`); the other ten already used fixed epochs.
- The files are **generated from the builders** and proven byte-identical to
  them, so the Swift test corpus and the portable vectors can never drift apart
  (see `ParserFixtureExtractionParityTests`).

`MANIFEST.json` in the corpus directory is the language-neutral index: for each
fixture it lists the provider, target parser, on-disk file(s), and the directory
layout the parser expects.

---

## The parser-output contract

Type: `ParserOutputContractRecord` (`AgentLensTests/Support/ParserOutputContract.swift`).
It is the **stable subset of `TokenUsage`** a parser must reproduce, chosen so it
is byte-identical across languages and platforms.

| Field | Source | Notes |
|---|---|---|
| `provider` | `TokenUsage.provider.rawValue` | e.g. `"Claude Code"`, `"Codex"` |
| `sessionId` | `TokenUsage.sessionId` | |
| `projectName` | `TokenUsage.projectName` | |
| `model` | `TokenUsage.model` | |
| `inputTokens` | `TokenUsage.inputTokens` | |
| `outputTokens` | `TokenUsage.outputTokens` | |
| `cacheCreationTokens` | `TokenUsage.cacheCreationTokens` | |
| `cacheReadTokens` | `TokenUsage.cacheReadTokens` | |
| `reasoningTokens` | `TokenUsage.reasoningTokens` | |
| `totalTokens` | `TokenUsage.totalTokens` | billed total = in+out+cacheCreate+cacheRead+reasoning |
| `costNanoUSD` | `round(TokenUsage.costUSD × 1e9)` | **integer** nano-USD, half-away-from-zero |
| `usageSource` | `TokenUsage.usageSource.rawValue` | |
| `provenanceMethod` | `TokenUsage.provenanceMethod.rawValue` | |
| `provenanceConfidence` | `TokenUsage.provenanceConfidence.rawValue` | |
| `estimatorVersion` | `TokenUsage.estimatorVersion` | drift-guards heuristic changes |

### What is deliberately excluded

Non-reproducible fields never enter the contract:

- `TokenUsage.id` — a random `UUID`.
- `startTime` / `endTime` / `createdAt` — wall-clock instants.
- device / remote fields (`deviceId`, `sourceDeviceId`, `isRemote`, …) — runtime
  state, not a function of the log.

Excluding the wall-clock is what makes the contract well-defined for the five
formerly-`Date()` fixtures: their parser-output projection is identical whether
the log carries the frozen stamp or any other timestamp
(`ParserFixtureExtractionParityTests.test_formerlyWallClockFixtures_areTimestampInvariant`).

### Cost representation

Cost is emitted as an **integer count of nano-USD** — `round(costUSD × 1e9)`,
rounding half away from zero. Integers have no floating-point text-formatting
drift, so the same value renders identically in Swift, C#, Kotlin, and TS. A
Windows port must apply the same scale + rounding (`Math.Round(cost * 1e9,
MidpointRounding.AwayFromZero)` in C#).

---

## The Mac golden

File: `AgentLensTests/Fixtures/ParserContract/parser-output-golden.json`
(`ParserOutputGolden`: `formatVersion`, `providers`, and one
`ParserFixtureContract` per fixture).

It is produced by running the **real production parser** for each provider
(`ClaudeCodeParser`, `FactoryDroidParser`, `CodexParser`, `HermesParser`) over the
extracted corpus and projecting each `TokenUsage` to the contract. Serialization
is canonical: sorted keys, stable pretty-printing, trailing newline. Usage rows
within a fixture are sorted deterministically so parser directory-iteration order
cannot perturb the file.

`ParserOutputContractGoldenTests` guards it three ways:

1. **Determinism** — the golden regenerated twice is byte-identical.
2. **Committed match** — a freshly generated golden equals the committed file
   (catches a stale golden after a parser change).
3. **Corpus↔golden consistency** — the golden regenerated from the committed
   on-disk files (not the inline builders) also equals the committed golden.

---

## Regenerating the corpus + golden (macOS)

App-hosted XCTest can lack the Documents-folder TCC grant, so the tests never
write into the repo. They emit fresh candidates to a writable output dir.

```bash
TEST_RUNNER_OPENBURNBAR_PARSER_CONTRACT_OUT=/tmp/obb-parser-contract-out \
  OPENBURNBAR_APP_TEST_FILTER=OpenBurnBarTests/ParserOutputContractGoldenTests \
  scripts/test-openburnbar-app.sh
# then:
cp /tmp/obb-parser-contract-out/ParserContract/* AgentLensTests/Fixtures/ParserContract/
xcodegen generate    # bundles the new resources
scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/ParserOutputContractGoldenTests
```

Regenerate whenever a parser's output legitimately changes; review the golden
diff as the record of that change.

---

## Phase 2 — the Windows byte-identical diff

Out of scope here (it needs Windows CI). When a Windows parser exists it will:

1. read the committed `AgentLensTests/Fixtures/ParserContract/` corpus,
2. produce `ParserOutputContractRecord`s using the identical field set + nano-USD
   cost rule,
3. serialize with the same canonical rules, and
4. assert **byte-identical** equality against `parser-output-golden.json`.

Any divergence is a real cross-platform parsing bug, caught before it can skew
usage or quota numbers.
