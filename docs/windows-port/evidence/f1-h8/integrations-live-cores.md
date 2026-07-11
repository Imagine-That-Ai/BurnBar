# Ledger row: mercury-media / cast-smarthub / home-assistant / text-expansion

**What this proves:** Production integration cores exist and are clean of sample/demo
defaults:

1. **Mercury:** MediaSessionStateMachine + wire/budget/consent/file-transfer cores under
   `windows/integrations/mercury`; the immutable snapshot, MOTW, Defender,
   approval, and threat-deny path has exact-candidate ARM64 host proof under
   `docs/windows-port/evidence/h2-host/mercury-file-transfer/`.
2. **Cast:** CastDiscoveryMerge + mDNS/DNS-SD discovery under `windows/integrations/cast`.
3. **Home Assistant:** HomeAssistantClient REST transport + config/token stores under
   `windows/integrations/homeassistant`.
4. **Text Expansion:** TextExpansionSettingsViewModel portable production settings path
   (global hook host residual is adapter-level).

**Tests:** Integration unit suites under windows/integrations (where present) and
Settings ViewModel text-expansion tests under windows/tests/settings.

**Operational residual:** Mercury screen/camera/audio capture, encode, calls,
WNS, and cross-device RFB remain visibly unavailable pending live device proof.
The file-transfer safety runtime and the other listed cores are production code,
not disclosure stubs.
