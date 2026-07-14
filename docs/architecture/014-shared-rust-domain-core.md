# ADR 014: Shared Rust Domain Core

## Context

OpenBurnBar has several behavior-identical domains implemented separately for
native platforms. Quota payload parsing exists in Swift and C#. CloudVault
cryptography exists in Swift, Kotlin, and C#. Hermes relay cryptography exists
in Swift and Kotlin. Golden fixtures detect drift after the fact but do not
remove the repeated implementation cost.

Provider log parsing is not currently such a domain. The fifteen production
parsers live in `OpenBurnBarCore`; Windows loads that Swift engine through its
C ABI, Linux reads through the shared engine, and Android and Cloud Functions
do not parse local provider logs. Rewriting those parsers in Rust would replace
one implementation rather than consolidate several.

## Decision

OpenBurnBar owns pure, duplicated business logic in
`crates/openburnbar-domain-core`. The workspace has one dependency-light Rust
library plus an explicit UniFFI adapter. A WebAssembly adapter is added only
when a real TypeScript-owned domain migrates. Transport, persistence,
network acquisition, authentication, secret storage, UI, and operating-system
integration remain in their existing owners.

Every migration is contract-first. Existing implementations must consume the
same language-neutral fixtures before Rust is introduced. A migrated consumer
passes through legacy, shadow, and Rust-enforced modes. Shadow comparison logs
only mismatch categories and core version, never payloads, values, credentials,
or payload hashes. The legacy implementation is deleted after the evidence and
rollback gates in `docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md` are satisfied.

The crate on `main` is the integration point. Work proceeds through short-lived,
independently reviewable branches; there is no long-lived SharedRust branch.

The quota pilot is controlled by `OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE` with
`legacy`, `shadow`, and `rust` values. Missing or invalid values fail closed to
legacy behavior.

## Consequences

- Quota parsing is the pilot because it removes real duplication with a small,
  pure input/output boundary.
- Swift, Kotlin, and C# use generated UniFFI bindings. Tauri may link the pure
  crate directly. Cloud Functions use a separately reviewed WASM adapter only
  for domains they actually execute.
- Existing iroh, remote, media, and libsignal crates remain separate ownership
  boundaries.
- FFI calls operate on complete payloads, files, or sessions rather than lines
  or fields.
- A domain does not move merely because it could be written in Rust. It moves
  only when at least two implementations exist or a measured platform/runtime
  constraint justifies replacing the current authority.
