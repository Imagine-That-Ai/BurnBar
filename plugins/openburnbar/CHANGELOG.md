# Changelog

All notable changes to the OpenBurnBar Cursor Plugin are recorded here.

## 1.0.0 — 2026-08-16

### Added

- Marketplace Cursor Plugin package: `.cursor-plugin/plugin.json` manifest
  with locked identity (name `openburnbar`, displayName `OpenBurnBar`,
  AGPL-3.0-only, category `integrations`).
- Hosted HTTP MCP server (`mcp.json`): one server at
  `https://mcp.burnbar.ai/mcp` with `Authorization: Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}`
  and the required plugin variable declared by name only.
- `README.md`, `LICENSE` (AGPL-3.0-only), `CHANGELOG.md`, and
  `assets/logo.svg` (copied from the editor extension artwork).
- Five skills (`openburnbar-operator`, `openburnbar-spend`,
  `openburnbar-resume`, `openburnbar-knowledge`, `openburnbar-doctor`), five
  slash commands, two rules, and two agents.
- Complete hosted-tool suite bodies: every skill and agent calls
  `burnbar_resolve_capabilities` first and names only allowed hosted tools;
  operator is resolve → search → body; spend uses `burnbar_recent_usage` +
  facets; resume is print-only `burnbar_list_resumable_conversations` →
  `burnbar_resume_conversation`; knowledge warns the default grant may lack
  `knowledge:read`; doctor diagnoses auth/capabilities/sealed fields vs the
  optional shim. All bodies carry sealed-field honesty and untrusted-data
  handling.
- `scripts/validate.mjs`: copy-aware, fail-closed structural validator
  (Node stdlib only, no package.json).
