# Linux Cloud Security Runbook

This runbook defines the Linux lower-trust cloud posture until a production Linux
attestation verifier and release-signing channel are provisioned.

## Principal And Trust Class

- Linux desktop uses a distinct App Check app id (`LINUX_APP_CHECK_APP_ID`,
  default placeholder `1:000000000000:linux:0000000000000000placeholder`).
- The backend classifies that id as `linux_lower_trust`; it is not treated as an
  Apple App Attest, Android Play Integrity, or web reCAPTCHA principal.
- Low-risk read/sync callables must use an explicit trust-class allow-list.
- High-risk actions must not pass from Linux App Check presence alone. They must
  consume a fresh `issueHighRiskActionNonce` nonce and route through a
  trusted-device step-up proof such as `enforceHighRiskOwnerAction`.

## Rollout And Kill Switches

- `ENFORCE_APP_CHECK=true` keeps callable App Check enforcement on.
- `REQUIRE_HIGH_RISK_NONCE=true` forces high-risk nonce consumption in production.
- `ALLOW_MOCK_APP_CHECK_ATTESTATION` is forced off in production by `config.ts`.
- Remove the real Linux id from `APP_CHECK_ALLOWED_APP_IDS` or unset
  `LINUX_APP_CHECK_APP_ID` to stop Linux minting while keeping Apple/Android/Web
  traffic unchanged.
- The Linux mint callable remains deployed but has no production mock verifier;
  without a real verifier, fixture claims cannot mint a token.

## SecretStore Setup

Approved high-value custody levels are Secret Service/libsecret, KWallet,
systemd credentials, and explicit headless passphrases. Plaintext local files are
refused for DB keys, Signal identity keys, CloudVault keys, refresh tokens,
capability roots, local-auth pins, and audit/export signing keys.

Headless deployments may provide secrets through systemd `CREDENTIALS_DIRECTORY`
files or documented `OPENBURNBAR_*` environment values. Diagnostics must log only
trust metadata, backend names, and redacted labels.

## Auth And Membership

Linux primary sign-in uses the system browser with PKCE loopback. Refresh/session
tokens must be stored through the approved SecretStore custody path. Linux
membership restore uses Stripe checkout or portal state and never links StoreKit.

## Telemetry And Support Bundles

Linux telemetry is dark unless consent and plan policy allow it. Support bundles,
logs, crash/error records, and provider traces must pass the shared redaction
policy before leaving the machine.

## Cloud Sync Privacy

Cloud sync treats local SQLite as source of truth. Linux sync may upload only
approved collection paths under `users/{uid}`. Private bodies, prompts, cookies,
tokens, and raw file paths must be sealed or omitted; watermarks advance only
after durable local commit.

## Blocked Production Evidence

Do not claim high-risk production Linux cloud availability until all are present:
real Firebase Linux App Check app id, real Linux platform attestation verifier,
release signing/provenance, and staging or production credentials for live
Firebase/Stripe traces. Until then, use emulator/fixture evidence and mark live
production rows blocked.
