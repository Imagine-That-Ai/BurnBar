# BurnBar Remote Security Notes

> ## ⚠️ SHIPPING STATUS: NON-SHIPPING PROTOTYPE — NOT the live security boundary
>
> The `burnbar-remote-*` crates are a Rust **prototype/foundation**. They are
> **not** wired into the shipping product and are **not** a dependency of
> `crates/openburnbar-iroh` (the transport the macOS app actually uses).
> Repo-wide, nothing in production calls `ControlPolicyGate::authorize`,
> `authorize_control`, or `InMemorySessionAuthorizer`.
>
> **The live remote-control authorization boundary is the Swift
> `PhoneControlAuthorityValidator`** (Ed25519-signed intents from an
> out-of-band-provisioned controller key, strictly-monotonic per-peer counter,
> ±5s freshness window, intent-hash binding, peer revocation), backed by the
> Firestore rules and the inbound NodeId allow-list in
> `AgentLens/Services/ComputerUse/` and `AgentLens/Services/IrohRelay/`. Audit
> THAT path, not this crate, for the control-path defense.
>
> `InMemorySessionAuthorizer` here is **test/prototype-only**: it emits grants
> with a zeroed handshake nonce and an unsigned policy hash. Do not mistake it
> for a production authorizer; it must be feature-gated before any of these
> crates is wired into a shipping target. (Security remediation H-6.)

This workspace is the Rust foundation for a remote desktop/control substrate.
It is not a complete end-user remote-control product until native capture,
encoder, decoder, renderer, input-injection, visible-indicator, and permission
prompt adapters are implemented per platform.

## Invariants

- Iroh endpoint identity is connectivity identity, not product authorization.
- A node id, relay URL, ticket, or successful QUIC connection never grants
  control by itself.
- `IrohTransportManager` returns `AuthorizedConnection` only after the wire
  session handshake succeeds.
- The session request binds Iroh endpoint id, client device id, account,
  workspace, requested mode, timestamp, and nonce.
- The host signs the request nonce into the `SessionGrant`; the client rejects
  any grant whose nonce, account, workspace, device id, mode, or expiry does
  not match its request.
- The host authorizer checks trusted device state, account/workspace binding,
  requested device id, local consent, allowed modes, and permission set.
- Session grants must verify against a trusted signer store. Embedded public
  keys are not trusted.
- Control events remain subject to grant expiry, permission checks, replay
  sequence, rate limits, high-risk confirmation, and kill-switch state.
- Relays are not trusted with plaintext.

## Key Storage

`SecureKeyStore` returns `Zeroizing<Vec<u8>>` and rejects unsafe key names.
The in-memory store is test-only. On macOS, the `macos-keychain` feature
enables `MacOsKeychainSecureKeyStore`, backed by Security.framework generic
password items under service `com.openburnbar.remote` with iCloud sync disabled.

Run the macOS secure-storage proof with:

```bash
cargo test -p burnbar-remote-security --features macos-keychain macos_keychain -- --nocapture
```

## Audit Chain

`TamperEvidentAuditLog` writes append-only JSONL entries. Each entry includes
schema version, index, account/workspace/session/device/endpoint context,
event kind, timestamp, a SHA-256 hash of the sensitive detail string, and the
parent entry hash. Raw detail strings are not written.

Appends run in `spawn_blocking` and take an advisory exclusive file lock across
validation and write, so concurrent writers do not race entry indices or parent
hashes.

Validation detects malformed JSON, unsupported schema, unexpected index,
parent mismatch, truncated file, and terminal head mismatch. Supplying a saved
head hash is required to catch tampering of the last entry.

## Proof Commands

Deterministic gate:

```bash
cargo fmt --check
cargo clippy --workspace --all-targets -- \
  -D warnings \
  -D clippy::unwrap_used \
  -D clippy::expect_used
cargo test --workspace
cargo doc --workspace --no-deps
cargo run -p burnbar-remote-bench
```

Optional live Iroh smoke:

```bash
BURNBAR_REMOTE_LIVE_RELAY=1 cargo run -p burnbar-remote-bench --bin iroh-smoke
BURNBAR_REMOTE_LIVE_RELAY=1 BURNBAR_REMOTE_FORCE_RELAY=1 cargo run -p burnbar-remote-bench --bin iroh-smoke
```

Repository proof script:

```bash
./scripts/e2e/burnbar-remote-hardening-proof.sh
```

The proof script also prints physical iOS/Android device inventory when those
tools are available. That inventory is evidence that the existing repo device
harnesses are reachable; it is not proof that this Rust workspace has native
mobile adapters yet.
