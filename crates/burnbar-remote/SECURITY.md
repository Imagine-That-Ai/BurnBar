# BurnBar Remote Security Notes

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
cargo clippy --workspace --all-targets -- -D warnings
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
