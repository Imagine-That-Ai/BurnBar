# Lint & suppression rationale — the strictness contract

OpenBurnBar runs every linter at maximum **defect-catching** strictness with **zero
baseline drift**. The permanence guarantee is enforced in CI by
[`scripts/ci/check-no-suppressions.sh`](../scripts/ci/check-no-suppressions.sh): a
fail-closed meta-gate that blocks any *new* lint/type suppression or checked-in
baseline from entering the tree without an explicit, greppable justification. Its
behaviour is itself regression-tested by
[`scripts/ci/check-no-suppressions.test.sh`](../scripts/ci/check-no-suppressions.test.sh).

This file is the **single source of truth** for what is deliberately allowed. If a
suppression is not justified inline (below) and not listed in the allowlist (below),
the gate fails the build. There is no separate baseline file to drift.

## What the gate detects

The gate scans tracked files for:

| Class | Pattern | Where |
|-------|---------|-------|
| Debt budget file | `budgets/*.json` (incl. nested) | `budgets/` |
| Lint baseline file | basename matches `*baseline*.{xml,yml,yaml}` | anywhere |
| Baseline re-introduction in config | `--baseline`, `detekt-baseline`, `swiftlint-baseline`, `baseline = file(…)` | `*.gradle{,.kts}`, `detekt*.y[a]ml`, `.swiftlint.yml`, `.github/workflows/*.y[a]ml` |
| ESLint suppression | `eslint-disable`, `-line`, `-next-line` | `*.{ts,tsx,mts,cts,js,jsx,mjs,cjs,astro,vue,svelte}` |
| TypeScript escape | `@ts-ignore`, `@ts-expect-error`, `@ts-nocheck` (comment-leading, incl. `///`) | same as ESLint |
| Python lint waiver | `# noqa` | `*.{py,pyi}` |
| Kotlin/Java suppression | `@Suppress(`, `@file:Suppress(`, `@SuppressLint(`, `@SuppressWarnings(` | `*.{kt,kts,java,gradle}` |
| detekt inline waiver | `// detekt:` | `*.{kt,kts,java,gradle}` |
| SwiftLint suppression | `swiftlint:disable` | `*.swift` |
| Rust lint allow | `#[allow(` / `#![allow(` | `*.rs` |

## How to justify a suppression

**1. Inline `reason:` token (preferred — granular, self-documenting).**
Put a `reason: <why>` marker **inside a comment** on the directive's own line — or on a
comment line **directly above** it (where `rustfmt` relocates an attribute's comment,
and the natural spot for a multi-line directive). The marker must be in comment position
(not inside the directive's own string arguments) and carry real text (≈8+ chars), so it
cannot be gamed. Examples:

```kotlin
@Suppress("LargeClass") // reason: cohesive crypto facade kept whole for Swift byte-parity.
```
```rust
// reason: crate-root re-exports of UniFFI-exported types; not referenced in-crate.
#[allow(unused_imports)]
```
```swift
// swiftlint:disable:next force_try // reason: test-only precondition, never ships.
```

**Python `# noqa`:** a *coded* waiver (`# noqa: E402`, `# noqa: S608,N802`) is accepted on
its own — the code names exactly what is waived and `ruff` enforces it is real and still
needed (`RUF100`). A **bare `# noqa`** is rejected; add the code(s) or a `reason:`.

**ESLint:** the directive's native `-- <description>` counts as justification, e.g.
`// eslint-disable-next-line no-console -- prints CLI banner to stdout`.

**2. Allowlist an exact path (for whole-file or generated artifacts).**
Use this only for generated lint baselines, tracked debt-budget files, and genuine
file-level suppressions. **Exact paths only — globs are rejected**, and every entry must
match a currently-tracked file (a stale entry fails the build closed, forcing cleanup
when the artifact is deleted). For a source file, scope the entry to the permitted token
kind with `path | kind[,kind]`; any *other* suppression kind in that file is still gated.
Kinds: `eslint-disable`, `ts-suppress`, `noqa`, `kotlin-suppress`, `detekt`,
`swiftlint-disable`, `rust-allow`.

<!-- BEGIN:suppression-allowlist -->
```text
# Exact paths only (globs rejected). `path | kind[,kind]` scopes a source file to
# the named occurrence kind(s); a bare path allows a budget/baseline artifact.

# --- Debt-budget ratchets: deleted at zero; CI fails on increase (docs/TECH_DEBT_METRICS.md) ---
budgets/hand-maintained-ts-baseline.json
budgets/knip-baseline.json
budgets/try-optional-baseline.json
budgets/unchecked-sendable-baseline.json
budgets/unsafe-cast-baseline.json

# --- Generated ktlint baselines: plan D7 burn-down (ktlintFormat + delete) ---
android/app/config/ktlint/baseline.xml
android/openburnbar-iroh-relay/config/ktlint/baseline.xml

# --- File-level TypeScript suppressions (token-scoped) ---
functions/src/types/legacy.ts | eslint-disable
website/src/scripts/dotConstellation.ts | ts-suppress
website/src/scripts/easterEggFx.ts | ts-suppress
website/src/scripts/emberSwarm.ts | ts-suppress
website/src/scripts/pretextShrinkwrap.ts | ts-suppress

# --- Rust crate-root re-exports (token-scoped): two #[allow(unused_imports)] on UniFFI re-exports.
# Allowlisted rather than annotated inline because crates/openburnbar-iroh/** changes trigger a full
# AAR rebuild-parity gate; the justification lives here instead of churning the FFI source.
crates/openburnbar-iroh/src/lib.rs | rust-allow
```
<!-- END:suppression-allowlist -->

## Allowlist hygiene

- Each entry above is **debt with a deletion plan**, not a permanent exception. When the
  underlying work lands (TypeSpec strangler, ktlint burn-down, debt budgets hitting
  zero), delete the entry **and** the artifact in the same PR — the gate fails closed on a
  stale entry, so this is enforced, not aspirational.
- New entries require a one-line rationale and should be rare. Prefer the inline `reason:`
  mechanism, which keeps the justification next to the code.
- The gate reads only the FIRST `BEGIN…END:suppression-allowlist` block (markers must be
  whole-line HTML comments); a second BEGIN anywhere fails the build closed.

## Deliberately out of scope (no silent caps)

Owned by dedicated workstreams and folded in when each reaches zero, so the boundary is a
known decision rather than a blind spot:

- **`# type: ignore` (Python, ~38 sites)** — mypy/ruff strictness workstream (plan D12).
- **`knownDrift` schema tokens** — gated by `tools/schema-sync` (plan D10).
- **Per-rule lint config (rules left off)** — lives in each linter's config + plan Phase 4;
  this gate governs *suppressions and baselines*, not which rules are enabled.

## Known limitations (recoverable, fail-closed)

- A directive token appearing inside a **string literal** is flagged like a real one. This
  is safe (fail-closed) — recover with a `reason:` comment or an allowlist entry.
- **Extensionless** scripts (shebang, no extension) and exotic source extensions are not
  scanned. There are none with suppressions today; add the extension to `EXT_PATTERNS`
  when one appears.
- A `reason:` for the line above must sit on a `//` line or a single-line `/* … */`; a
  reason on the *continuation* line of a multi-line block comment is not recognised
  (fail-closed). Use a `//` line or put `reason:` on the directive's own line.
