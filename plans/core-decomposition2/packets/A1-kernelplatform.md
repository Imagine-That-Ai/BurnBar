# Packet A1: OpenBurnBarKernelPlatform — dead public-type deletions

STATE: QUEUED  LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
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
