# 016 — Safari extension trust and daemon admission boundary

**Status:** Accepted

**Date:** 2026-08-10

## Context

The Safari Web Extension runs JavaScript in untrusted pages and communicates
with a short-lived native extension process. That native process needs
authenticated access to OpenBurnBar's local daemon and App Group, but it must
not inherit the unsandboxed host app's authority.

The security question is not merely whether the process runs as the same macOS
user. Any same-user process may be compromised or malicious. The question is
whether the caller is the exact signed, provisioned, embedded OpenBurnBar Safari
appex and whether each requested capability is still authorized by the daemon.

## Decision

1. The native extension is a distinct product:
   `com.openburnbar.app.safari-extension`.
2. It is sandboxed and receives only outbound network access, App Group
   `group.com.openburnbar.app`, and the shared OpenBurnBar Keychain access
   group needed for daemon/gateway token resolution.
3. The appex does not receive provider credentials or general filesystem
   authority.
4. Native messages enter through `SafariWebExtensionHandler`. Content scripts
   cannot contact native code directly; they relay through the MV3 background
   context.
5. The handler authenticates to the daemon with the normal socket token and
   must also satisfy the daemon's signed-peer policy.
6. Daemon admission may name this exact appex identity/designated requirement.
   If platform behavior prevents reliable direct admission, the handler must
   relay through the already-admitted host process.
7. The implementation must never replace signed-peer admission with a broad
   same-user, path-prefix, App Group membership, or unsigned-development
   exception in release builds.
8. Admission proves caller identity, not action authority. Every Safari action
   still passes capability attenuation, live URL scope, deny rules, trust mode,
   approval, audit, tab ownership, and panic state.
9. App Group payloads are untrusted transport objects. Every chunk set is
   bounded and carries a run/request owner, expected count/size, digest,
   creation/expiry time, and single-consumer cleanup.

## Release invariants

- App path:
  `OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex`
- Bundle ID: `com.openburnbar.app.safari-extension`
- Extension point: `com.apple.Safari.web-extension`
- MV3 manifest path:
  `OpenBurnBarSafariExtension.appex/Contents/Resources/manifest.json`
- Direct profile: dedicated all-devices `MAC_APP_DIRECT` profile for the appex
- MAS profile: App Store distribution profile, never the host's profile
- Host and appex profiles independently authorize
  `group.com.openburnbar.app` and `TEAMID.com.openburnbar.app`
- Signed direct and MAS host apps retain the same shared App Group and Keychain
  group as the signed appex
- Nested code is signed before the appex; the appex is signed before the app
- Both archive and exported-package verification inspect the appex explicitly
- `codesign --verify --deep` is supplemental only; it does not replace explicit
  nested identity, entitlement, profile, or manifest checks

## Consequences

- The extension remains an attenuated adapter rather than an alternate daemon
  authority.
- Release infrastructure needs a second provisioning profile and independent
  nested signing verification.
- Existing host profiles must be regenerated with the shared App Group; the MAS
  host profile also needs shared Keychain authorization. This is a release
  migration gate, not something source validation can prove.
- MAS scripts cannot pass host `CODE_SIGN_ENTITLEMENTS` globally. They use the
  host-only `OPENBURNBAR_HOST_CODE_SIGN_ENTITLEMENTS` build setting.
- A valid signature alone is not sufficient to run page actions.
- Same-user App Group tampering remains a residual risk and is handled through
  authenticated, integrity-checked, bounded, expiring envelopes.

## Rejected alternatives

- Admit every process signed by the same team.
- Admit every caller running as the logged-in user.
- Treat App Group file access as caller authentication.
- Give the appex the unsandboxed host entitlement set.
- Disable daemon codesign admission when Safari is enabled.

See the broader product decision in
[the dated Safari ADR](../adr/2026-08-10-openburnbar-safari-extension.md).
