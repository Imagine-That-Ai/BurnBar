# ADR-001: Cryptographic Architecture — Phone as a Secure Window

**Status:** Accepted
**Date:** 2026-06-06

This ADR records the cross-platform cryptographic architecture for BurnBar. It is
structured like `plugins/platforms/burnbar/SECURITY_V4.md`: a control table, numbered
constructions, an explicit honest-residual-risk section, and evidence-file callouts.
The architecture is **per-platform, per-channel** — the right primitive is chosen for
each `(platform, channel)` cell, and the iOS App Store binary is deliberately held free
of the official Signal library.

## What this ADR decides

| Decision | Construction | Standard / anchor |
|---|---|---|
| **Device ↔ device** on every platform that can run the official Signal library (macOS / Android / daemon) uses the genuine **libsignal Double Ratchet** with **PQXDH** session establishment. | `libsignal-double-ratchet` | Signal Protocol (Perrin & Marlinspike); PQXDH (Signal, 2023) |
| **At-rest cloud sealing** is **libsignal HPKE seal** — RFC 9180 single-shot HPKE over **X25519 / HKDF-SHA256 / AES-256-GCM** — written by libsignal-bearing platforms. | `libsignal-hpke-seal` | RFC 9180 (HPKE); RFC 5869 (HKDF) |
| **iOS opens** the same at-rest envelope with **Apple CryptoKit (iOS 17+)** HPKE — same RFC 9180 ciphersuite, interoperable bytes, **NO libsignal in the iOS App Store binary**. | `cryptokit-hpke-atrest` | RFC 9180 (HPKE), Apple CryptoKit |
| **Phone ↔ AI gateway** keeps the **homegrown Double Ratchet** (the Hermes relay lane), because the gateway must decrypt to run the model — libsignal there buys nothing. | `homegrown-double-ratchet` | Signal Double Ratchet (homegrown impl.); see `SECURITY_V4.md` |
| **iOS is a libsignal-FREE secure satellite worldwide** — it never links, bundles, or ships the official Signal library on any channel. | `none-satellite` on `device_to_device` | App-Store-clean policy invariant |

The shorthand: **the phone is a secure window, not a Signal endpoint.** It reads
sealed cloud data via CryptoKit-interoperable HPKE and talks to other devices and the
AI gateway over encrypted transports, but the heavyweight official Signal Double Ratchet
runs only where the App Store distribution rules let it.

## 1. Device ↔ device — official libsignal Double Ratchet (PQXDH)

macOS, Android, and the daemon establish device-to-device sessions with the **genuine
official libsignal**: PQXDH for the initial key agreement and the Double Ratchet for the
per-message symmetric ratchet. This is true Signal Protocol — forward secrecy and
post-compromise security on every message, with the X3DH-successor PQXDH adding a lattice
KEM to the handshake. Only `packages/libsignal-bridge` imports `@signalapp/libsignal-client`
directly (enforced by `check_signal_boundary()` in
`scripts/ci/check_burnbar_license_posture.py`); everything else consumes the bridge.

**iOS has no device-to-device libsignal channel at all** — its `device_to_device`
capability is `none-satellite`. The phone reaches peers through the transport-encrypted
satellite path, never by running Signal Protocol locally.

## 2. At-rest sealing — libsignal HPKE seal, opened on iOS via CryptoKit

Cloud-stored content is sealed with **HPKE (RFC 9180), single-shot, base mode**, over the
ciphersuite **DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM**. On macOS, Android,
the daemon, and the backend write path this is performed by **libsignal's HPKE seal**
(`libsignal-hpke-seal`). The decisive interop property is that **the wire bytes are plain
RFC 9180** — so the iOS reader opens the identical envelope using **Apple CryptoKit's
HPKE (iOS 17+)** with the matching ciphersuite, and **never links libsignal**. iOS at-rest
is therefore `cryptokit-hpke-atrest`: at-rest sealing of equivalent strength, produced by an
interoperable, standards-conformant implementation, with no Signal library in the App Store
binary.

This interop is a load-bearing claim and MUST be pinned by a cross-implementation test
vector (see Residual Risks §6.2): a libsignal-sealed envelope that CryptoKit opens, and a
CryptoKit-sealed envelope that libsignal opens, byte-for-byte.

## 3. Phone ↔ AI gateway — homegrown Double Ratchet (retained)

The Hermes AI-gateway lane keeps the **homegrown Double Ratchet** on **every** platform,
including the libsignal-bearing ones. This is deliberate: the gateway terminates encryption
to run the model, so the end-to-end relationship is **phone ↔ gateway**, not phone ↔ model.
Putting official libsignal on this hop would add no end-to-end secrecy versus the model
itself, while the homegrown ratchet already delivers forward secrecy and post-compromise
security between phone and gateway. The full construction (v4 signed lane, signed
`ratchet_init`, Padmé size minimization, all-key safety code, signed rotation) is documented
in `plugins/platforms/burnbar/SECURITY_V4.md` and implemented in `gateway/crypto/`.

## 4. Platform × Channel capability matrix

This is the single source of truth. Each cell names the exact cryptographic model in use.

| Platform | device_to_device | at_rest | ai_gateway |
|---|---|---|---|
| **macos** | `libsignal-double-ratchet` | `libsignal-hpke-seal` | `homegrown-double-ratchet` |
| **android** | `libsignal-double-ratchet` | `libsignal-hpke-seal` | `homegrown-double-ratchet` |
| **daemon** | `libsignal-double-ratchet` | `libsignal-hpke-seal` | `homegrown-double-ratchet` |
| **backend** | _(no channel)_ | `libsignal-hpke-seal` | `homegrown-double-ratchet` |
| **ios** | `none-satellite` | `cryptokit-hpke-atrest` | `homegrown-double-ratchet` |

Libsignal-bearing models (the ones iOS must NEVER carry on ANY channel):
`libsignal-double-ratchet`, `libsignal-hpke-seal`.

### Enforced invariants

1. **iOS is libsignal-free on every channel.** iOS never uses a libsignal-bearing model.
   iOS `at_rest` is `cryptokit-hpke-atrest` (CryptoKit RFC 9180 interop, no libsignal link).
   This is the App-Store-clean hard rule and a build-failing violation if broken.
2. **Real Signal Protocol device-to-device** is mandatory for macos / android / daemon
   (`libsignal-double-ratchet`). `ios.device_to_device` MUST be `none-satellite`. `backend`
   has no device-to-device channel.
3. **The AI gateway is `homegrown-double-ratchet` on every platform** — never libsignal,
   because the gateway decrypts plaintext to run the model.

## 5. Claim mapping (model → allowed marketing claim)

Each model maps to exactly one approved external claim. Marketing/UX copy MUST use only the
mapped claim for the model actually in force on that platform/channel.

| Model | Allowed claim |
|---|---|
| `libsignal-double-ratchet` | "Signal Protocol" |
| `libsignal-hpke-seal` | "Signal at-rest sealing" |
| `cryptokit-hpke-atrest` | "At-rest HPKE sealing (CryptoKit, RFC 9180, interoperable with the libsignal seal, no libsignal link)" |
| `homegrown-double-ratchet` | "Hardened encrypted gateway (homegrown Double Ratchet, forward secrecy)" |
| `none-satellite` | "secure satellite (transport-encrypted)" |

> Doc-safety note: "Signal Protocol" and "Signal at-rest sealing" are reserved for the genuine
> official-libsignal lanes only. The CryptoKit-at-rest and homegrown-gateway rows are phrased
> deliberately **without** branding them "Signal" and without any token the product-doc guard
> forbids (`FORBIDDEN_PRODUCT_CLAIMS` in `scripts/ci/check_burnbar_license_posture.py`, e.g.
> "Signal-cl​ass"). The machine-readable source of truth for this table is the `claims` block of
> `docs/security/crypto-architecture-policy.json`, which the checker asserts byte-for-byte —
> **iOS must NEVER map to "Signal Protocol".**

## 6. HONESTY — what we do and do NOT claim

This section is deliberately blunt. It exists so neither the product nor its copy overstates
the guarantee.

- **The Hermes AI gateway DECRYPTS prompts to run the model.** The end-to-end encryption on
  this lane is **phone ↔ gateway**, NOT phone ↔ model. The model provider's process sees
  plaintext prompts and completions by construction. **Do NOT claim "the assistant cannot
  read your messages."** The honest claim is that the *transport* between the phone and the
  gateway is a hardened (homegrown Double Ratchet) channel with forward secrecy and
  post-compromise security — not that the AI itself is blind to your content.

- **iOS is a "secure, Signal-sealed cloud" window, NEVER "Signal Protocol on your iPhone."**
  The iPhone/iPad reads cloud-sealed data through a CryptoKit RFC 9180 HPKE path that is
  interoperable with libsignal's at-rest sealing — equivalent strength, no Signal library in
  the App Store binary. It does **not** run the official Signal Double Ratchet locally. Any
  copy implying "Signal Protocol runs on your iPhone" is false and forbidden.

- **The matrix is the truth.** A claim is only permitted if the model in force on that exact
  `(platform, channel)` cell maps to it under §5. iOS at-rest may say "interoperable HPKE
  at-rest sealing"; it may not say "Signal Protocol."

## 7. Residual risks (honest)

### 7.1 Counsel legal-release gate is still OPEN

Shipping the Signal/libsignal-bearing lanes (and the App-Store-clean iOS satellite framing)
is gated on **external-counsel** AGPL and app-store/commercial-distribution review, which is
**not yet cleared**. The release-review evidence is fail-closed `pending` until counsel signs
off (`docs/legal/AGPL_RELEASE_REVIEW_PACKET.md`,
`docs/legal/agpl-release-review.evidence.template.json`,
`scripts/ci/check_agpl_legal_release_review.py`). Do not market a Signal-enabled release as
fully cleared until this gate closes.

### 7.2 CryptoKit ↔ libsignal at-rest interop is unproven until a vector locks it

The entire iOS at-rest story (§2) rests on the two HPKE implementations producing and opening
byte-identical RFC 9180 envelopes. This MUST be locked by a committed cross-implementation
**test vector** — a libsignal-sealed envelope CryptoKit opens, and a CryptoKit-sealed envelope
libsignal opens — and that vector MUST run in CI. Until that vector exists and is green, the
interop is an assumption, not a fact, and a silent ciphersuite drift could break iOS reads in
the field.

### 7.3 iOS 17 minimum for the CryptoKit at-rest read path

The CryptoKit HPKE APIs used to open at-rest envelopes require **iOS 17+**. On **iOS 16** the
device cannot use the HPKE read path; it falls back to a **legacy AES-256-GCM Keychain vault**
for at-rest material. That legacy vault is a narrower, device-local construction (no HPKE
sender authentication, no RFC 9180 KEM) and is a strictly transitional path retired as the
iOS-17 floor advances. Copy targeting iOS 16 users must reflect the legacy vault, not the HPKE
seal.

### 7.4 Inherited gateway residual risks

The phone ↔ AI-gateway lane inherits every residual risk catalogued in
`plugins/platforms/burnbar/SECURITY_V4.md` §"Honest residual risk" — notably signing-key
compromise on the signed lane, the absence of post-quantum protection on the homegrown ratchet
(deferred to a future hybrid-KEM wire version), FS/PCS being chat-lane-only after init, and the
timing/frequency/ordering metadata visible to a store-and-forward relay. This ADR does not
re-close any of those; it scopes them.

## 8. Evidence / policy-as-code pointers

The matrix and invariants in §4 are intended to be machine-checked, not merely documented:

- **`docs/security/crypto-architecture-policy.json`** — the canonical machine-readable encoding
  of the platform × channel matrix, the libsignal-bearing model set, the invariants (§4), and
  the claim mapping (§5). This file is the data the checker reads.
- **`scripts/ci/check_burnbar_crypto_architecture_policy.py`** — the CI gate that loads the
  policy JSON and **fails the build** on any invariant violation: an iOS cell carrying a
  libsignal-bearing model, a macos/android/daemon device-to-device cell that is not
  `libsignal-double-ratchet`, an `ai_gateway` cell that is not `homegrown-double-ratchet`, or a
  claim that does not map to the model in force.
- **`packages/e2ee-backend-policy/lib/index.js`** — the backend's runtime crypto-backend
  resolver (`resolveCryptoBackend`). It fails closed in BurnBar mode when the Signal backend is
  unavailable unless a classical fallback is **explicitly** allowed, mirroring this ADR's
  "libsignal where it can run, never silently degraded" stance.

## 9. Related

- `plugins/platforms/burnbar/SECURITY_V4.md` — the phone ↔ AI-gateway (homegrown ratchet) lane.
- `docs/security/network-egress-isolation.md` — network-layer isolation for gateway deployments.
- `scripts/ci/check_burnbar_license_posture.py` — AGPL posture + Signal-bridge boundary +
  product-doc claim hygiene that scans this ADR.
