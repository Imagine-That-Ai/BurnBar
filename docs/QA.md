# OpenBurnBar QA

OpenBurnBar treats test results, built artifacts, installed behavior, physical
device/browser behavior, provider state, and public distribution as separate
proof surfaces. A green unit suite is not proof that a signed app contains the
right nested products; a signed app is not proof that a user can complete the
workflow; a successful local workflow is not proof that the public artifact is
the same candidate.

## Core policy

Every release claim should name:

- the exact Git commit/candidate
- the artifact identity and digest when applicable
- the environment and distribution channel
- the automated suites run
- the manual scenarios run
- the proof surface still unverified
- any blocked, skipped, or substituted evidence

`BLOCKED`, `SKIPPED`, and `NOT_RUN` are not passes.

## Automated entrypoints

```bash
make test-full
node --test scripts/ci/classify-ci-impact.test.mjs
bash scripts/diff-coverage-ts-self-test.sh
```

Platform- and feature-specific commands live beside their implementation and
are linked from the relevant QA plan.

## Warning hygiene

Canonical Xcode entrypoints apply
`scripts/lib/xcode-source-classification.sh`. It centralizes two
revision-bound transitive-package repairs for Xcode 27 without disabling
warning classes:

- Abseil compiler include fragments and package metadata are not standalone
  compilation inputs, so the shared xcconfig excludes only those file shapes.
- GoogleSignIn 8.0.0's umbrella imports two headers conditionally even though
  each header already contains the same platform guard. Xcode 27 reports them
  as omitted umbrella members when Swift imports the module on macOS. The
  canonical wrappers resolve the locked package graph, apply the reviewed
  checksum-bound unconditional imports under an exclusive cache lock, disable
  automatic re-resolution for the build, and restore the checkout byte-for-byte
  on exit. The headers' own guards preserve the API on macOS, iOS, and Catalyst.
- Xcode and SwiftPM package-workspace locks use a writable local `/tmp` root by
  default, independently of DerivedData. Set `OPENBURNBAR_XCODE_PROCESS_TMPDIR`
  only when the replacement has been proved writable to launchd/XCTest child
  processes; stale or unavailable external-volume `TMPDIR` values are ignored.

Keep this compatibility contract centralized and test-bound. Do not replace it
with a global `-Wno-*`, `CLANG_WARN_*=NO`, or `SWIFT_SUPPRESS_WARNINGS`
setting, because that would hide future first-party regressions.

## Manual plans

- [Safari Extension QA](qa/SAFARI_EXTENSION_QA.md)
- [Chat pane tabs QA](qa/CHAT_PANE_TABS_QA.md)

## Evidence hygiene

- Preserve the candidate branch, HEAD, status, configuration, and artifact
  digest with the result.
- Never relabel evidence from an older candidate after a code fix.
- Record negative/failure-path results, not only the happy path.
- Do not use screenshots alone when logs, signatures, entitlements, or machine
  readable receipts are the authoritative proof.
- Do not use CI or simulator success as a substitute for physical/manual proof.
- Do not use public URL liveness as a substitute for signature, notarization,
  version, and nested-bundle verification.

## Accessibility

Feature QA must include keyboard-only navigation, VoiceOver labels/order,
reduced motion, increased contrast, text scaling where supported, visible focus,
and error recovery that does not rely on color alone.

## Performance

Measure the user-visible path, not only microbenchmarks. Capture cold and warm
startup, interaction latency, memory growth during repeated operations, payload
sizes, cancellation latency, and behavior under degraded dependencies. Bind
measurements to the exact candidate and hardware/browser configuration.
