# CloudVault v1 fixtures

- `cloudvault-deterministic-kat.json` pins deterministic crypto primitives and
  AES-GCM framing.
- `cloudvault-search-contract.json` pins the portable CloudVault search v1
  transform before Rust implementation. Swift and Kotlin legacy tests consume
  the same file.

The search fixture uses explicit plaintext for normal cases and a deterministic
`numberedTokens` input descriptor for adversarial bounds. Consumers expand that
descriptor to `prefix0 prefix1 ... prefixN-1` before calling the operation.
Array order is contractual. The fixture does not represent shadow duration,
production traffic, or deletion-gate evidence.

The Rust core, UniFFI surface, and generated Wasm package all execute this same
fixture. Production platform consumers continue to use their legacy authority
until the separate shadow-mode routing changes accumulate promotion evidence.
