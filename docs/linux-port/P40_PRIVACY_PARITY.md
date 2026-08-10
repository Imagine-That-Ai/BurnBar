# P-40 Data and Privacy Parity Slice

This slice closes the Linux settings gap where consent flags were displayed as
read-only values even though the daemon already exposes the typed
`daemon.config.update` contract. It also adds deliberately narrow daemon-owned
local deletion, encrypted export, and retention contracts, plus
trusted-device-gated cloud-account export and erasure. The local UI can
inventory, preview, delete, encrypted-export, and apply bounded retention only
to the proxy-route log and text-expansion store; cloud data control keeps
authorization and payload bytes out of the renderer. Raw provider credentials
and arbitrary local transcript files remain excluded.

## Delivered

- Telemetry, privacy opt-in, and cloud-sync choices are writable through the
  typed `LinuxShellBridge.configUpdate` path and therefore `daemon.config.update`.
- The settings store reports `idle`, `pending`, `success`, and `error` states;
  controls are disabled while a write is pending and the response snapshot is
  committed only after the daemon returns it.
- A missing packaged bridge fails closed with an actionable error. No
  localStorage or other renderer-only persistence is used for privacy choices.
- `BurnBarLinuxPrivacyService` exposes metadata-only inventory for two
  allowlisted stores. It rejects traversal, symlinks, unsafe owner/perms, and
  unknown stores; it never returns file paths or contents.
- Preview tokens bind the selected stores to fingerprints, owner/perms, and a
  five-minute expiry. Execute requires the exact phrase `DELETE LOCAL DATA`,
  revalidates the token and scope, unlinks only the allowlisted files, and
  returns an idempotent typed receipt.
- Typed daemon RPCs and the Tauri bridge expose inventory/preview/execute; the
  Settings surface shows store state/bytes, requires scope selection and
  confirmation, refreshes inventory after success, and preserves an explicit
  unavailable state when the packaged bridge lacks the contract.
- `7c8a214ce6` and `825e081bda` add selected-scope encrypted export. The daemon
  reads only the fixed allowlist, rejects unsafe paths/owners/permissions,
  bounds payload and bundle size, seals the payload with PBKDF2-HMAC-SHA256
  (100,000 iterations) plus AES-GCM authenticated headers, writes owner-only
  output, and returns only typed metadata. The renderer clears the passphrase
  after the request and never persists it.
- The account data export path follows the existing trusted-device/App Check
  cloud authority: the renderer supplies only an optional domain scope and
  destination, while the daemon obtains nonce-bound authorization, calls
  `exportUserData`, validates the schema/size envelope, and writes the JSON
  response with owner-only permissions. The bridge returns only a bounded
  receipt (`destinationPath`, byte count, schema version), never cloud payload,
  credentials, sealed references, or action proofs.
- The daemon owns bounded age and size retention for both allowlisted local
  stores. Settings reads the current policy, requires the exact confirmation
  phrase `APPLY RETENTION POLICY`, and applies a complete two-store policy.
  Invalid bounds, malformed stores, unsafe paths, or partial policies fail
  closed without deleting data.
- Account erasure is available through the daemon-owned
  `linuxAccountCloudDataDelete` path. The renderer forwards only
  `DELETE MY ACCOUNT`; the daemon owns trusted-device authorization, Firebase
  credentials, callable execution, and the redacted deletion receipt. Partial
  secret, storage, cloud-data, or Auth deletion is shown as incomplete and
  remains retryable instead of being reported as success.
- The current daemon response may omit path/status envelope fields; the store
  preserves the already-loaded daemon facts until an explicit config refresh,
  while consent/provider fields come from the returned canonical snapshot.
- Local deletion/export/retention controls do not touch transcripts,
  credentials, account data, or arbitrary files. Account export and erasure are
  separate server-authoritative paths. Encrypted database recovery bundles are
  exposed separately; cross-device recovery-key custody and P-40 recovery
  certification remain open. The existing redacted support diagnostics export
  remains linked separately.

## Validation

Focused UI/store tests cover fixture writes, packaged-bridge absence, payload
preservation, local deletion/export/retention, complete account erasure,
partial-erasure retry, and unsupported lifecycle copy. Run from
`apps/linux-desktop`:

```bash
npx vitest run src/surfaces/settings/SettingsSurface.test.tsx --reporter=dot
npx tsc --noEmit
npm run build
```

The source lane also records Rust formatting/tests, daemon privacy tests,
account-control tests, the P-40 proof tests, and the production bundle verifier.
Live GNOME Keyring/KWallet behavior, native save-picker behavior, trusted-device
account erasure, backend deletion receipts, recovery receipts, and multi-device
propagation remain environment/backend work and are not claimed by this slice.

## Follow-up contract

The remaining work is execution and scope closure, not missing local RPC
scaffolding:

1. Execute account erasure against the deployed backend with a real approved
   trusted device, and capture complete, partial-failure, retry, offline, and
   idempotency receipts.
2. Add local transcript export only after a daemon history contract explicitly
   binds source identity and retention semantics; keep arbitrary files and
   credentials outside this scope.
3. Certify retention, encrypted export, account data control, recovery-bundle
   handoff, locked-keyring behavior, and cross-device propagation on the exact
   signed candidate in all seven Linux environments.

Until those receipts exist, the Linux shell and parity ledger must not infer
certification from source code or renderer state.
