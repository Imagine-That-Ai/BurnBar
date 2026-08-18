# OpenBurnBar mobile parity

Status: **mobile parity remediation in progress**.

This directory is the inventory, schema-boundary, and evidence system for iOS /
iPadOS / Android parity. It does **not** claim product parity. A file existing,
a screen compiling, or a unit test passing is not validation.

M0 froze the capability inventory and evidence rules. M1 records every
mobile-consumed Firestore document and callable against TypeSpec or a named
legacy boundary, and adds generated-consumer + fixture checks. M2 pins shared
policy vectors (windows, quota, entitlements, trust, AAD, relay chunks, errors).
M3 landed auth/sync/provider/device/store **unit and contract** work. M4 landed
Pulse/Burn/Streams/Inbox **unit and contract** work (shared product vectors).
M5 landed Hermes/Pi/Mercury/Computer Use **unit and contract** work (stop/cancel,
thread isolation, MercuryPeer/heartbeat, fail-closed KATs). M6 landed the OS
integration matrix plus unit-pinned push routing, permission/stale/duplicate
behavior, and widget privacy. M7 landed shared a11y label contracts, Dynamic
Type / scalable tokens, and documented performance budgets. M8 landed
candidate-fingerprint and release-evidence **scaffolding**. It is **not
validated**. Live App Check, physical-device transfer, StoreKit/Play readback,
paired-Mac traces, Computer Use live panic, VoiceOver/TalkBack, profiler
captures, and store publication stay blocked.

## Canonical files

| File | Role |
|---|---|
| `mobile-capability-registry.json` | One row per accepted capability, divergence, and non-goal |
| `mobile-route-map.json` | Primary/secondary/gated destinations, deep links, push, widgets |
| `mobile-ownership-map.json` | Source → iOS / iPadOS / Android ownership |
| `mobile-sync-ownership.json` | Mac publishes; mobile mirrors (read-only) |
| `mobile-schema-boundary.json` | Every mobile Firestore collection and callable → TypeSpec or named legacy |
| `mobile-evidence-schema.json` | Candidate/device/evidence pointer contract |
| `accepted-non-goals.json` | Signed-off non-goals (including pixel-identical UI) |
| `mobile-parity-ledger.json` | VAL-MOB-001–015 plus per-capability rows |
| `mobile-parity-ledger.md` | Generated from the JSON. Do not hand-edit |
| `fixtures/schema/` | Cross-language golden + negative decode fixtures |
| `fixtures/policy/` | Shared policy/KAT vectors |
| `fixtures/product/` | Pulse/Burn/Streams/Inbox + Hermes/Mercury/Computer Use + OS/a11y golden vectors |
| `mobile-os-integration-matrix.json` | Notification, deep-link, widget, Live Activity, durable-UI, background matrix |
| `mobile-a11y-performance-policy.json` | Contrast/touch/reduced-motion + Pulse O(n) / retry budgets |
| `store-readback.json` | ASC/TestFlight + Play closed-test fields (empty/blocked) |
| `evidence/` | Candidate-bound bundle. Empty/blocked until a clean candidate + named devices + authorized store readback |
| `FULL_MOBILE_PARITY_REMEDIATION_PLAN.md` | Copied plan; not a second “done” document |

## Commands

```bash
# Inventory/schema/path integrity. Blocked rows remain visible.
node scripts/mobile-parity/validate-mobile-parity.mjs --allow-blocked

# Promotion gate. Must stay nonzero until required rows are proven.
node scripts/mobile-parity/validate-mobile-parity.mjs

# Generated Markdown must match the ledger JSON.
node scripts/mobile-parity/render-mobile-parity-ledger.mjs --check

# Schema canon + generated consumers + fixtures (also invoked by check-drift.sh).
node scripts/mobile-parity/check-mobile-schema-boundary.mjs
node scripts/mobile-parity/check-mobile-generated-consumers.mjs
node scripts/mobile-parity/check-cross-language-fixtures.mjs
node scripts/mobile-parity/check-mobile-policy-vectors.mjs
node scripts/mobile-parity/check-mobile-product-vectors.mjs
./tools/schema-sync/check-drift.sh

# OS integration matrix + a11y/performance + release evidence scaffolding.
node scripts/mobile-parity/check-mobile-os-integration.mjs
node scripts/mobile-parity/check-mobile-a11y-performance.mjs
node scripts/mobile-parity/check-release-evidence.mjs
node scripts/mobile-parity/record-candidate-fingerprint.mjs --stdout

# Unit tests for validator branches (including negative cases).
node --test scripts/mobile-parity/*.test.mjs
```

## Honesty

- `productParityClaim` is `false`.
- VAL-MOB-003 is `implemented` for automated contract checks, not `validated`.
- VAL-MOB-004/005/006/007/008/009 scrutiny/unit rows are `implemented` (KAT). Physical, live App Check, and live StoreKit/Play stay `blocked`.
- VAL-MOB-008/010/011/012/013/014/015 physical and store rows stay `blocked`. KAT scrutiny rows are `implemented` only. Historical Android-only Computer Use rows cannot close iPhone/iPad.
- Historical evidence is `historical` / `stale` / `rebind-required`, never PASS.
- Dirty trees cannot close a candidate (`git status --short` is part of the fingerprint).
- VAL-MOB-015 cannot be marked `validated` without store readback fields.

## Remaining blocked gates

Until the program definition-of-done in the plan is met, these stay blocked:

- Named iPhone / iPad / Android devices and an installed candidate digest
- Live App Check, physical sign-in, offline/online device runs
- Physical Pulse/Burn/Streams/Hermes/Mercury/Computer Use traces
- Physical notification, widget, Live Activity, keyboard, rotation, split-screen
- Manual VoiceOver / TalkBack and profiler captures
- Authorized TestFlight / App Store Connect and Play closed-test readback
- Clean (`closable`) candidate fingerprint bound to those artifacts
