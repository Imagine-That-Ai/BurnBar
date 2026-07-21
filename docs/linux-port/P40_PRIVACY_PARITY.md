# P-40 Data and Privacy Parity Slice

This slice closes the Linux settings gap where consent flags were displayed as
read-only values even though the daemon already exposes the typed
`daemon.config.update` contract. It also adds deliberately narrow daemon-owned
local deletion and export contracts, plus a trusted-device-gated cloud-account
export. The local UI can inventory, preview, delete, and encrypted-export only
the proxy-route log and text-expansion store; the cloud export writes the
server-authoritative bounded JSON envelope to an owner-only local path without
returning payload bytes through the renderer. Raw provider credentials and
arbitrary local transcript files remain excluded.

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
- The current daemon response may omit path/status envelope fields; the store
  preserves the already-loaded daemon facts until an explicit config refresh,
  while consent/provider fields come from the returned canonical snapshot.
- Account erasure, retention, and recovery-key workflows remain unavailable
  capability states. Local deletion/export controls do not touch transcripts,
  credentials, account data, or arbitrary files; authenticated cloud export is
  a separate server-authoritative path. The existing redacted support
  diagnostics export remains linked separately.

## Validation

Focused UI/store tests cover fixture writes, packaged-bridge absence, payload
preservation, success state, and unsupported lifecycle copy. Run from
`apps/linux-desktop`:

```bash
npx vitest run src/surfaces/settings/SettingsSurface.test.tsx --reporter=dot
npx tsc --noEmit
npm run build
```

The final PR also records Rust formatting/tests and the production bundle
verifier. Live GNOME Keyring/KWallet behavior, native save-picker behavior,
account deletion, retention enforcement, recovery receipts, and multi-device
propagation remain environment/backend work and are not claimed by this slice.

## Follow-up contract

To move the remaining unavailable rows to an actionable state, add canonical
daemon RPCs with explicit scope and policy before changing this UI:

1. Extend the existing local preview/execute pattern to account deletion only
   after backend erasure authority, audit receipts, retry/partial-failure
   handling, and offline behavior are specified.
2. Extend the selected-scope local export with a native save destination and
   import/restore validation. Add local transcript export only after a daemon
   history contract explicitly binds source identity and retention semantics.
3. Define retention expiry and recovery-key custody, including locked keyring
   and cross-device propagation states.

Until those contracts exist, the Linux shell must keep the remaining controls
disabled and must not infer completion from renderer state.
