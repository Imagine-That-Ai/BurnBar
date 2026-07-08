# Portable prompt-injection-wrap contract vectors (VAL-P0-HARNESS-025)

`llm-safe-wrap-vectors.json` freezes the **byte-exact** output of the shipped macOS
`LLMSafeContent.wrapUntrusted` / `resealTruncatedUntrusted`
(`AgentLens/Services/ContextBuilder.swift` — the R18 crown-jewel prompt-injection
wrap, OWASP LLM01) for a set of named cases.

These are the *portable* half of the R18 hardening story: the app target already has
`AgentLensTests/Active/Security/PromptInjectionHardeningTests.swift` (behavioral
assertions), but had **no byte-level vectors** a Windows / Kotlin / TS
re-implementation could diff against. This file is that oracle.

## Named vectors

Each entry carries `input`, an optional `provenance` (for `wrapUntrusted`), the
`function` it exercises, the exact `expectedOutput` bytes, and a `note`.

| name | function | proves |
| --- | --- | --- |
| `defang-embedded-close-sentinel-and-ignore-instructions` | `wrapUntrusted` | an embedded `</UNTRUSTED_CONTENT>` boundary is defanged to the U+2011 form and an "ignore previous instructions" payload survives verbatim as inert data; exactly one genuine close tag remains |
| `defang-case-insensitive-sentinel` | `wrapUntrusted` | mixed / lower-case sentinels are defanged case-insensitively |
| `provenance-stamp-and-sanitize` | `wrapUntrusted` | provenance is stamped with attribute-escaping neutralized (`"`→`'`, `<`/`>` stripped, CR/LF→space, sentinel defanged) |
| `truncation-reseal-severed-close` | `resealTruncatedUntrusted` | a prefix cut that severed the close tag is re-sealed (missing `</UNTRUSTED_CONTENT>` + CRITICAL RULE re-appended) |
| `truncation-reseal-lost-rule-tail` | `resealTruncatedUntrusted` | a cut inside the trailing rule restores only the missing remainder |
| `truncation-reseal-noop-complete-block` | `resealTruncatedUntrusted` | a complete sealed block is left byte-identical (no-op / idempotence) |

## Oracle

`AgentLensTests/Active/Security/LLMSafeWrapVectorTests.swift` loads this file from the
`OpenBurnBarTests` resource bundle (wired in `project.yml`) and asserts the shipped
function reproduces every vector **byte-for-byte**. If the shipped wrap drifts from
the frozen bytes, that test fails and forces a conscious regeneration.

## Regeneration (bootstrap only)

```sh
scripts/ci/generate-llm-safe-wrap-vectors.sh          # rewrite this file
scripts/ci/generate-llm-safe-wrap-vectors.sh --check  # fail if stale (CI-friendly)
```

The generator extracts the `enum LLMSafeContent` block **verbatim** from
`ContextBuilder.swift` (never a hand-copy of the security-critical code), compiles it
with a tiny driver via the system `swift`, and emits deterministic JSON
(`.sortedKeys`). `LLMSafeContent` depends only on Foundation, so this runs headlessly
with no app build or SPM resolve. The committed XCTest — not the generator — is the
durable drift gate.

Non-goal: hoisting `wrapUntrusted` into Core. That is gated post-G0-Option-A; this
delivers the portable vectors + the Mac match test now.
