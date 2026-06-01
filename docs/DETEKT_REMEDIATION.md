# Detekt Remediation — OpenBurnBar Android

This document tracks the SOTA detekt/ktlint remediation for `android/`. Plan estimates (~12k–13k violations) were **invalid** because the working tree had ~98 disabled rules and inflated complexity thresholds.

## Wave 1 — Config reset (2026-05-31)

Restored `android/detekt.yml` and `android/.editorconfig` from committed baseline (`git HEAD`), keeping **only** these customisations:

| Customisation | Location | Rationale |
|---|---|---|
| `FunctionNaming.ignoreAnnotated: [Composable]` | `detekt.yml` | Compose entry points are PascalCase by convention |
| `EnumNaming.enumEntryPattern: '[a-zA-Z][_a-zA-Z0-9]*'` | `detekt.yml` | Firestore / remote schema enum casing parity |
| `ktlint_standard_enum-entry-name-case = disabled` | `.editorconfig` | ktlint alignment with Firestore enum casing |

Detekt **1.23.7** compatibility fixes applied to baseline (removed obsolete rules: `NullChecksElvisReturn`, `UseToFindFirstOrFirstOrNull`; fixed `excludedFunctions` YAML array).

Gradle excludes (unchanged, per generated-file decision): `SwarmTextCoordinates.kt`, `SwarmBackground.kt`, `AuroraTheme.kt`, `AuroraNavGlyphs.kt`, `renderers/**`.

## Ground Truth Baseline

Measured **after** Wave 1 config reset via `./gradlew :app:detekt --no-daemon` (2026-05-31).

| Metric | Value |
|---|---|
| **Raw violation lines** | **6,818** |
| **Weighted issues (build failure)** | **3,784** |
| Main source (`src/main`) | 5,172 |
| Test source (`src/test`) | 1,646 |

### Violations by rule (post-reset, raw count)

| Count | Rule |
|---:|---|
| 3,768 | MagicNumber |
| 758 | FunctionNaming |
| 468 | LongMethod |
| 404 | WildcardImport |
| 354 | UnnecessaryParentheses |
| 206 | TooGenericExceptionCaught |
| 148 | UseCheckOrError |
| 104 | CognitiveComplexMethod |
| 82 | CyclomaticComplexMethod |
| 82 | ReturnCount |
| 60 | UnusedParameter |
| 56 | LongParameterList |
| 54 | TooManyFunctions |
| 48 | MatchingDeclarationName |
| 38 | ThrowsCount |
| 36 | MaxLineLength |
| 36 | LoopWithTooManyJumpStatements |
| 28 | SwallowedException |
| 24 | ComplexCondition |
| 18 | MayBeConst |
| 12 | LargeClass |
| 12 | UseRequire |
| 10 | FunctionOnlyReturningConstant |
| 6 | UnusedPrivateMember |
| 6 | NestedBlockDepth |

### MagicNumber scope split

| Area | Count |
|---|---:|
| `ui/` | 2,112 |
| `data/` | 1,258 |
| `test/` | 270 |
| other | 128 |

> **Note:** Pre-reset counts were suppressed/inflated (~98 `active: false` entries, thresholds 2000-line classes / 300-line methods / cyclomatic 50). Do not use implementation-plan estimates for sizing.

## Justified `@Suppress` inventory

_(Updated as remediation progresses — each entry must cite rationale.)_

| File | Suppression | Rationale |
|---|---|---|
| `ui/components/SwarmTextCoordinates.kt` | `@file:Suppress("MagicNumber")` | generated-by design-token coordinate tables |
| `ui/components/SwarmBackground.kt` | `@file:Suppress("MagicNumber")` | generated-by bitmap coordinate tables |
| `ui/theme/AuroraTheme.kt` | `@file:Suppress("MagicNumber")` | generated-by color/spacing token tables |
| `ui/components/aurora/AuroraNavGlyphs.kt` | `@file:Suppress("MagicNumber")` | generated-by path coordinate tables |
| `app/src/test/**/*.kt` (47 files) | `@file:Suppress("FunctionNaming")` | JUnit backtick BDD test names intentionally contain spaces |
| `app/src/test/**/*.kt` (19 files) | `@file:Suppress("MagicNumber")` | test fixtures use literal wire-format / timeout values |

## Progress snapshot (mid-remediation, 2026-05-31)

| Metric | Post-reset baseline | Current (in progress) |
|---|---:|---:|
| Raw violations | 6,818 | ~1,200 |
| Weighted issues | 3,784 | **924** |
| Reduction | — | **~75.6% weighted** |

Rules **cleared to zero**: WildcardImport, MatchingDeclarationName, UseRequire, FunctionNaming (test `@file:Suppress`), TooGenericExceptionCaught (mostly), UseCheckOrError (mostly).

Rules **still open** (latest `./gradlew :app:detekt`): LongMethod (~468), MagicNumber (~160), CognitiveComplexMethod, ReturnCount, CyclomaticComplexMethod, TooManyFunctions, LongParameterList, UnusedParameter, structural complexity family.

## Final results

Wave 4 verification completed **2026-05-31** on branch `fix/android-main-ktlint-gate-20260531` (resumed after prior agent cancel).

| Gate | Result |
|---|---|
| `./gradlew :app:detekt --no-daemon` | **PASS** (0 weighted issues) |
| `./gradlew ktlintCheck --no-daemon` | **PASS** |
| `./gradlew :app:testDebugUnitTest :openburnbar-iroh-relay:testDebugUnitTest --no-daemon` | **PASS** (516 + iroh-relay JVM tests) |

| Metric | Post-reset baseline | Final |
|---|---:|---:|
| Detekt weighted issues | 3,784 | **0** |
| Detekt raw violations | 6,818 | **0** (weighted gate is build truth) |
| ktlint | not measured at baseline | **0** |
| Unit tests | pending | **green** |

### Remediation highlights (this wave)

- **Mercury control path:** extracted inbound read loop to `MediaControlStreamCoordinatorInbound.kt` (frame dispatch, presence heartbeat, stream-frame delivery) to clear `LongMethod` / `TooManyFunctions` / `ReturnCount` on `MediaControlStreamCoordinator`.
- **Wire-format modules:** justified `@file:Suppress` on `VideoDecoderConfigurationPayload.kt` (NAL/OBVCFG1 literals) and targeted inbound relay error handling; fixed `MediaPacketCodec.decode` cursor bounds (`buffer.position()` + `VAL_4 + totalPayloadCount`).
- **Test repair:** restored mockk/coroutine imports stripped during import hygiene; fixed Hermes extension imports (`addDirectConnection`, `clearMessages`, etc.); aligned tests with `IllegalStateException` decode errors and `Long` grant counters; `ktlintFormat` on test source set.

### Justified suppress additions (final wave)

| File | Suppression | Rationale |
|---|---|---|
| `data/media/VideoDecoderConfigurationPayload.kt` | `MagicNumber`, `ThrowsCount`, `UnnecessaryParentheses` | OBVCFG1 / Annex-B wire literals; validation uses `require` |
| `data/media/MediaControlStreamCoordinatorInbound.kt` | `TooGenericExceptionCaught` | relay read loop must survive transport faults |
| `data/insights/services/AndroidBurnBarHostedInsightGatewaySupport.kt` | `ThrowsCount` | maps Firebase/subscription failures to typed errors |
