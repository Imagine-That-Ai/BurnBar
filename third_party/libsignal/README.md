# Official Signal libsignal Pin

OpenBurnBar pins official Signal libsignal in `manifest.json`.

Current pin:

- Tag: `v0.94.4`
- Tag object: `03c449017b57eccbda715b8b018dce5dff603ac6`
- Source commit: `46d867c986f66201e34e7ae20ce423eec742bf3f`
- License: `AGPL-3.0-only`

Use this manifest for Swift, Kotlin/Android, Rust, and Node bridge work. Do not
introduce a second Signal Protocol implementation or a different libsignal fork
without updating the legal notices, source-offer docs, and compliance gate.

Runtime status lives in `runtime-readiness.json`. The readiness verifier is
intentionally fail-closed until every platform writes new private-domain
ciphertext through official libsignal and the migration/read-only legacy gates
are complete:

```bash
bash scripts/ci/verify-libsignal-runtime-readiness.sh
```

The Node bridge now has a real protocol harness, not just a package-load check:

```bash
npm test --prefix packages/libsignal-bridge
```

That harness establishes an official libsignal session, consumes one-time
prekeys, marks Kyber prekeys used, decrypts out-of-order Whisper messages,
rejects replay, and proves safety-number changes when the remote identity key
changes. It is evidence for the Node protocol surface; it is not proof that
macOS, iOS, Android, Functions, or hosted-service writes have migrated.
