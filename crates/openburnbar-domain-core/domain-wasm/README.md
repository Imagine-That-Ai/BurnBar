# OpenBurnBar Domain Core Wasm

This crate exposes the deterministic, browser-safe subset of the shared domain
core. It does not accept, export, or persist WebCrypto `CryptoKey` handles. The
Console keeps non-extractable key custody in WebCrypto and calls this package
only for AAD construction, hashing, key identifiers, and fixed-purpose keyed
hashes when raw vault bytes are already part of the existing operation. The
CloudVault search API similarly accepts an owned copy of raw vault bytes for one
complete text/query operation, zeroizes that copy, and never accepts a browser
key handle. Its typed result exposes ordered hashes without JSON parsing.

The JavaScript, TypeScript declaration, and Wasm files under
`apps/console/vendor/openburnbar-domain-core-wasm/` are generated artifacts.
Regenerate and verify them with:

```bash
./scripts/build-domain-core-wasm.sh
./scripts/build-domain-core-wasm.sh --check
```

The build pins `wasm-bindgen-cli` and tests the generated package against the
canonical CloudVault deterministic KAT and search contract before writing or
accepting an artifact.
