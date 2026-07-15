# Packet A1: OpenBurnBarKernelPlatform — dead public-type deletions

STATE: CONVERGED — 0 deletions, 0 internalizations (all 12 "dead" candidates
reclassified ALIVE by the compiler; the cluster's real curation is A9 test-only,
BLOCKED on WS-B). See "Converged reality" below.
LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
BASELINE-TOUCHING: budgets/public-api-baseline.json (--update allowed if no sibling A-packet in flight; see A0-README)

Read plans/core-decomposition2/packets/A0-README.md shared rules FIRST
(re-verification protocol, ratchet etiquette, full V-list).

## Scope — dead deletion candidates (12)

All 12 live in Platform/LinuxLocalPeerDiscovery.swift or the crypto shims:

- `Platform/LinuxLocalPeerDiscovery.swift`: BurnBarAvahiBrowsePlan,
  BurnBarAvahiEventKind, BurnBarAvahiPublishPlan, BurnBarDiscoveredService,
  BurnBarLinuxDeviceAdapterReport, BurnBarLinuxDeviceControlPlan,
  BurnBarLinuxParityLedgerRow, BurnBarLinuxParityStatus,
  BurnBarLocalPeerCapability, BurnBarPixelClockFirmwareLaneReport
- PlatformAESGCMSealedBox, PlatformHPKESealedBox (crypto shim types — check
  `canImport`-gated twins on the Linux side before deleting; a type that is
  dead on macOS may be the Linux-path implementation).

CAUTION (Linux parity): this module is the Linux-port substrate. The Linux
parity ledger/validators reference Swift symbol names from scripts — the
report's grep already covers scripts, but re-verify WITH markdown/json
included (`git grep -w <Name>`) since parity evidence files are json/md.
Expect some of these 12 to reclassify as alive; delete only what survives.

## Method

1. Re-verify each name per A0-README. 2. Delete survivors (whole file if it
empties). 3. If LinuxLocalPeerDiscovery.swift loses only SOME types, keep the
file coherent. 4. Full V-list. 5. Converged-reality section into this card.

## Converged reality (executed on core-decomp2/a1-kernelplatform)

Verdict: **all 12 "dead" candidates reclassify to ALIVE. Zero deletions, zero
internalizations land in A1.** No code changed; this packet is documentation-only.
The compiler is the oracle and it rejected every removal/internalization.

### Why the classifier over-counted 12/12 here

`OpenBurnBarKernelPlatform`'s `Platform/LinuxLocalPeerDiscovery.swift` is a single
cohesive Linux-parity subsystem (mDNS/Avahi publish+browse, IoT/PixelClock device
adapters, parity-ledger rows). Its ~30 public types form one reference graph. The
`--report` classifier greps each TYPE NAME with word boundaries outside the
declaring file; it cannot see a type reached only through **member access** or a
**function's inferred return type** (documented blind spot in
`scripts/debt/check-public-api-budget.sh` header + A9 card). Every one of the 12 is
consumed by a *sibling* public entry point that survives:

- `BurnBarLocalPeerCapability` → public property `BurnBarLocalPeerMetadata.capabilities` (+ `.allCases` default arg).
- `BurnBarAvahiPublishPlan` / `BurnBarAvahiBrowsePlan` → results of public `BurnBarAvahiCommandFactory` methods/vars.
- `BurnBarAvahiEventKind` → public property `BurnBarDiscoveredService.eventKind`.
- `BurnBarDiscoveredService` → result of public `BurnBarAvahiBrowseParser.parse`; param of public adapter `evaluate(services:)`.
- `BurnBarLinuxParityStatus` → public property of `BurnBarLinuxParityLedgerRow` / `BurnBarPixelClockFirmwareLaneReport`.
- `BurnBarLinuxParityLedgerRow` / `BurnBarLinuxDeviceControlPlan` → public stored props of `BurnBarLinuxDeviceAdapterReport`.
- `BurnBarLinuxDeviceAdapterReport` → result of public `BurnBarPixelClockLinuxAdapter.evaluate` / `BurnBarLinuxIoTAdapterSuite.evaluate`.
- `BurnBarPixelClockFirmwareLaneReport` → result of public `evaluateFirmwareLane`.
- `PlatformAESGCMSealedBox` / `PlatformHPKESealedBox` (PlatformSupport.swift) → results of public `PlatformCrypto.sealAESGCMDetached` / `hpkeSealP256SHA256AESGCM256`, both **consumed cross-module** by `OpenBurnBarKernelCrypto` (CloudVaultCrypto.swift, HermesRelayCrypto.swift). These two are permanently public.

### Compiler proof

Internalizing all 12 (drop `public` on the 12 decl lines) and rebuilding the Core
package produced **34 compile errors** — "property/method/initializer cannot be
declared public because its type/result/parameter uses an internal type" and
"enum … is internal and cannot be referenced from a default argument value".
Reverted; tree pristine. Baseline build (untouched tree) = green.

### The cluster's real fix is A9, not A1

Non-test cross-module references to the *entry points* of this file
(`BurnBarAvahiCommandFactory`, `BurnBarAvahiBrowseParser`, `BurnBarPixelClockLinuxAdapter`,
`BurnBarLinuxIoTAdapterSuite`, `BurnBarLocalPeerMetadata`, `BurnBarAvahiRegistrationResult`,
`BurnBarAvahiLifecycleEvidence`, `BurnBarAvahiDisabledState`, `BurnBarPixelClockFirmwarePrerequisites`)
= **none**. The file's only external consumer is
`OpenBurnBarCore/Tests/OpenBurnBarLinuxCoreFoundationTests/LinuxLocalPeerDiscoveryTests.swift`
(`@testable import OpenBurnBarCore`). So the *entire* connected component (12
"dead" + 9 "test-only") is internalizable **as one unit** once WS-B per-module
`@testable` lands — that is packet **A9** (BLOCKED on WS-B), which owns the 9
test-only names. The 12 "dead" ones are mutually referenced with those 9 and
therefore cannot be split into an independent A1 change. The 2 crypto types are
neither dead nor test-only; they stay public.

Net: `budgets/public-api-baseline.json` is UNCHANGED for
`OpenBurnBarKernelPlatform` (62 types / 291 members). No baseline `--update`.
