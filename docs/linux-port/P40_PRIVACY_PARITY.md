# P-40 Data and Privacy Parity Slice

This slice closes the Linux settings gap where consent flags were displayed as
read-only values even though the daemon already exposes the typed
`daemon.config.update` contract. It also adds a deliberately narrow daemon-owned
local deletion contract: the UI can inventory, preview, and delete only the
proxy-route log and encrypted text-expansion store after an exact confirmation.
Account erasure, full-data export, retention, and recovery-key workflows remain
unavailable and are not implied by this local action.

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
- The current daemon response may omit path/status envelope fields; the store
  preserves the already-loaded daemon facts until an explicit config refresh,
  while consent/provider fields come from the returned canonical snapshot.
- Full-data export, account erasure, retention, and recovery/retention are
  presented as unavailable capability states. The existing redacted support
  diagnostics export remains linked separately. The local deletion control does
  not touch transcripts, credentials, account data, or arbitrary files.

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
verifier. Live GNOME Keyring/KWallet behavior, account deletion, recovery
receipts, and multi-device propagation remain environment/backend work and are
not claimed by this slice.

## Follow-up contract

To move the remaining unavailable rows to an actionable state, add canonical
daemon RPCs with explicit scope and policy before changing this UI:

1. Extend the existing local preview/execute pattern to account deletion only
   after backend erasure authority, audit receipts, retry/partial-failure
   handling, and offline behavior are specified.
2. Export selected scopes with native save destination, encryption policy, and
   import/restore validation.
3. Define retention expiry and recovery-key custody, including locked keyring
   and cross-device propagation states.

Until those contracts exist, the Linux shell must keep the remaining controls
disabled and must not infer completion from renderer state.
