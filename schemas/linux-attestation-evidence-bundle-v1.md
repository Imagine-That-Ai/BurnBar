# Linux attestation evidence bundle v1

The privileged broker transfers complete TPM evidence to the daemon in one
sealed `memfd`. It never writes the bundle to a filesystem path and never sends
it over the broker JSON frame.

The byte layout is:

1. Eight ASCII magic bytes: `OBBATST1`.
2. One unsigned 32-bit big-endian JSON-header length. The length must be between
   2 and 16,384 bytes.
3. The canonical UTF-8 JSON header validated by
   `linux-attestation-evidence-bundle-header-v1.schema.json`. Canonicalization
   uses no insignificant whitespace, recursively sorts object keys by their
   Unicode code-point order, and preserves array order. The header schema is
   restricted to ASCII strings and safe non-negative integers, so this rule is
   identical in the Rust and Node implementations. A verifier must parse the
   header, re-serialize it canonically, and reject it unless the bytes are
   identical.
4. The four record bodies in header order, with no padding or trailing bytes.

Every record offset is absolute from byte zero. Records must be contiguous,
non-overlapping, within the descriptor size, and individually match their
declared SHA-256 digest. The complete descriptor is limited to 64 MiB and must
match the size and SHA-256 in the broker response.

The descriptor must be a regular anonymous file with `FD_CLOEXEC` and all of
`F_SEAL_WRITE`, `F_SEAL_GROW`, `F_SEAL_SHRINK`, and `F_SEAL_SEAL`. The daemon
rejects zero, multiple, unsealed, writable, sparse, oversized, truncated, or
digest-mismatched descriptors. It streams the accepted descriptor directly to
the fixed verifier ingress and closes it on every terminal path.

The `ima_ascii_runtime_measurements` record is the complete, byte-for-byte
contents of `/sys/kernel/security/ima/ascii_runtime_measurements` and must be
valid UTF-8 with no NUL bytes. The `uefi_binary_bios_measurements` record is the
complete binary firmware event log. A supported host fails closed if either log
is unavailable, exceeds the bound, changes so that replay no longer matches the
quoted PCRs, contains an unsupported record, or would need to be truncated.

The cloud challenge is exactly 32 random bytes encoded as canonical unpadded
base64url. Quote `extraData` is the SHA-256 of these byte fields joined by one
`0x00` separator, with no trailing separator:

1. UTF-8 `openburnbar.linux.tpm-quote.v1`
2. The decoded 32 challenge bytes
3. UTF-8 `appId`
4. UTF-8 `deviceId`
5. UTF-8 `appVersion`
6. UTF-8 `architecture`
7. UTF-8 `releaseDigestSha256`
8. UTF-8 `policyId`
9. UTF-8 `attestationKind`

All binding strings are the broker-authoritative values returned by
`describe_binding`. `qualifyingDataSha256` is the lowercase hexadecimal encoding
of the resulting 32-byte digest. The broker and verifier independently recompute
this value and reject any mismatch.

The broker also returns the three uncompressed TPM quote components as
canonical standard base64: `quoteAttestationBase64` is the marshalled
`TPMS_ATTEST`, `quoteSignatureBase64` is the marshalled `TPMT_SIGNATURE`, and
`quotePcrValuesBase64` is the tpm2-tools-compatible PCR blob. The Keylime 7.14
v2.5 one-shot verifier receives the compound quote
`r<attestation>:<signature>:<pcr-values>` and the standard-base64 encoding of
the 32 qualifying-data bytes as its nonce. The facade must reconstruct these
values from the strict broker fields; it must not accept a client-provided
compound quote or nonce.

The `installed_manifest` record is the packager's recursively key-sorted,
whitespace-free JSON serialization followed by exactly one ASCII LF byte. The
verifier must hash these exact record bytes and require that digest to equal the
challenge's `releaseDigestSha256`. It verifies the
detached `installed_manifest_signature` against the release trust root before
using any manifest field. The signed manifest's `firebaseAppId`,
`packageVersion`, `packageArchitecture`, and `policyId` must exactly match the
challenge binding; `appId` must remain `dev.openburnbar.OpenBurnBar`, and
`brokerProtocolVersion` must be `2`. The upload receipt, broker bundle metadata,
stored upload declaration, and complete descriptor must all agree on byte
length and SHA-256.
