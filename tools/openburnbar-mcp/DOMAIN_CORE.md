# Local MCP shared domain core

The local MCP routes its pure CloudVault transforms through
`domain_core_cloudvault.py`. Set
`OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE` to `legacy`, `shadow`, or `rust`.
The default remains `legacy` until the protected promotion gate changes the
signed rollout profile.

`./setup.sh` builds the host-native Rust library, regenerates the pinned UniFFI
Python binding, writes a package receipt, and verifies the complete loaded
version/ABI/source tuple. Rust mode also verifies the host OS/architecture and
the SHA-256 digests of both the native library and generated binding before its
first operation. Any identity, load, validation, or authentication failure in
Rust mode fails closed; it never invokes the Python implementation.

Shadow mode returns the legacy value and emits only an operation name, bounded
comparison category, and core version. Inputs, outputs, keys, AAD values, user
identifiers, and hashes are never diagnostic fields.

Run the production-package contracts with:

```bash
./scripts/test-domain-core-python.sh -q
```

The path-addressable rollback implementation remains in
`cloudvault_legacy.py` until the crypto promotion and stable-release deletion
gates pass. The exact migration/deletion ledger is
`docs/contracts/domain-core-python-consumer-manifest.json`.
