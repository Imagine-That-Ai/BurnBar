# P-11 Usage Catalog Parity

Status: implementation slice complete; normalized macOS/Linux parser corpus and
installed runtime evidence remain separate parity gates.

## What changed

The Linux shell now ships a checked 33-provider catalog in
`apps/linux-desktop/src/providerPathRegistry.ts`. Each row contains:

- Linux provider route id and canonical `AgentProvider` case token
- Linux logical path and canonical discovery file pattern
- XDG/home expansion behavior and resolved-path session identity behavior
- Honest ingestion coverage (`local-parser`, `api-backed`, or `unavailable`)
- A user-facing coverage note used by Settings and onboarding

The catalog is checked against the committed macOS/core sources by
`providerPathRegistry.swiftParity.test.ts`:

- `AgentProvider.swift` must expose exactly the same 33 case tokens.
- `AgentProviderLogDiscovery.swift` must contain every row's path and pattern,
  including grouped Swift switch cases and Linux conditional paths.
- `ParserRegistry.swift` must expose exactly the 27 local parser registrations
  represented by `local-parser` rows.
- The six canonical providers without a local parser remain explicit:
  `OpenAI`, `OpenBurnBar`, `DeepSeek`, and `MiMo` are API/native-ledger backed;
  `OpenClaude` and `OMP` are unavailable for local ingestion.

No parser implementation is invented for a provider that is absent from the
canonical registry.

## User-facing behavior

Settings -> Engine Room shows a coverage summary (`27 local parsers, 4
API-backed sources, 2 unavailable local sources`) and labels every provider
path with its source state. Onboarding repeats the same count and explains that
API-backed and unavailable sources are not local scans. This prevents a path
row from implying that a parser exists merely because the provider is in the
canonical enum.

## Validation

Focused command from `apps/linux-desktop`:

```text
npx vitest run src/providerPathRegistry.test.ts src/providerPathRegistry.swiftParity.test.ts src/surfaces/settings/SettingsSurface.test.tsx --reporter=dot
```

Expected result: 3 test files, 26 tests passed.

The provider path tests also cover default and custom `XDG_CONFIG_HOME` /
`XDG_DATA_HOME` resolution for all 33 rows.

## Remaining parity work

This slice proves catalog/wiring truth, not equivalent parser output. The
following remain open and must stay visible in the parity ledger:

1. Run the canonical provider corpus through the real macOS and Linux ingest
   paths and compare normalized tokens, cost, model/provider identity,
   timestamps, provenance, and deduplication.
2. Add empty, malformed, permission-denied, rotation/symlink, migration, and
   multi-account fixtures for every declared local source.
3. Prove API/quota aggregation, recount, projections, cloud mirror, and account
   switching against the same candidate release and installed environments.
4. Wire real local ingestion for `OpenClaude` and `OMP` only after a canonical
   parser contract exists; until then their unavailable state is intentional.
5. Reconcile the legacy macOS `AgentProvider` file-pattern extension with the
   canonical cross-platform discovery table if both remain in use.

## QA checklist

- [x] 33 canonical provider cases have one and only one catalog row.
- [x] 27 `ParserRegistry` registrations have `local-parser` rows.
- [x] API-backed providers are not shown as local parsers.
- [x] Providers without a parser show an explicit unavailable state.
- [x] Linux conditional VS Code/Windsurf/Warp paths are checked.
- [x] Default and custom XDG path expansion is table-tested.
- [x] Settings renders the summary and per-row coverage labels.
- [x] Onboarding repeats the coverage summary and source boundary.
- [ ] Installed Linux runtime scans representative provider fixtures.
- [ ] macOS/Linux normalized corpus diff is exact for every supported source.
- [ ] Seven-environment release matrix and real account/quota evidence pass.
