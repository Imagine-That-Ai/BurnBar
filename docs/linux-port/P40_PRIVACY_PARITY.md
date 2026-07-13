# P-40 Data and Privacy Parity Slice

This slice closes the Linux settings gap where consent flags were displayed as
read-only values even though the daemon already exposes the typed
`daemon.config.update` contract. It deliberately does not pretend that Linux
has account erasure, destructive local deletion, full-data export, retention,
or recovery-key workflows: those actions remain visibly unavailable until the
daemon owns an audited scope, confirmation, receipt, and retry contract.

## Delivered

- Telemetry, privacy opt-in, and cloud-sync choices are writable through the
  typed `LinuxShellBridge.configUpdate` path and therefore `daemon.config.update`.
- The settings store reports `idle`, `pending`, `success`, and `error` states;
  controls are disabled while a write is pending and the response snapshot is
  committed only after the daemon returns it.
- A missing packaged bridge fails closed with an actionable error. No
  localStorage or other renderer-only persistence is used for privacy choices.
- The current daemon response may omit path/status envelope fields; the store
  preserves the already-loaded daemon facts until an explicit config refresh,
  while consent/provider fields come from the returned canonical snapshot.
- Full-data export, local deletion, account erasure, and recovery/retention are
  presented as unavailable capability states. The existing redacted support
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
verifier. Live GNOME Keyring/KWallet behavior, account deletion, recovery
receipts, and multi-device propagation remain environment/backend work and are
not claimed by this slice.

## Follow-up contract

To move the unavailable rows to an actionable state, add canonical daemon RPCs
with explicit scope and policy before changing this UI:

1. Preview and execute local/account deletion with confirmation, audit receipt,
   retry/partial-failure handling, and offline behavior.
2. Export selected scopes with native save destination, encryption policy, and
   import/restore validation.
3. Define retention expiry and recovery-key custody, including locked keyring
   and cross-device propagation states.

Until those contracts exist, the Linux shell must keep the controls disabled and
must not infer completion from renderer state.
