# Ledger row: mercury-media / cast-smarthub / home-assistant / text-expansion

**What this proves:** Production integration cores exist and are clean of sample/demo
defaults:

1. **Mercury:** MediaSessionStateMachine + wire/budget/consent/file-transfer cores under
   `windows/integrations/mercury` with Windows adapters for capture/encode/WNS.
2. **Cast:** CastDiscoveryMerge + mDNS/DNS-SD discovery under `windows/integrations/cast`.
3. **Home Assistant:** HomeAssistantClient REST transport + config/token stores under
   `windows/integrations/homeassistant`.
4. **Text Expansion:** TextExpansionSettingsViewModel portable production settings path
   (global hook host residual is adapter-level).

**Tests:** Integration unit suites under windows/integrations (where present) and
Settings ViewModel text-expansion tests under windows/tests/settings.

**Operational residual:** live device pairing and hardware capture on a given machine.
Cores are production code, not disclosure stubs.
