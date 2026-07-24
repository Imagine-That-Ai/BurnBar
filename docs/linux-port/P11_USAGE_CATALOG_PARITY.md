# P-11 Usage Catalog Parity

Status: source implementation complete; installed runtime and real-account
evidence remain separate parity gates.

## What changed

macOS and Linux now derive the 33-provider ingestion contract from one
authoritative, versioned manifest:
`contracts/provider-ingestion-catalog.json`. Each row contains:

- Linux provider route id and canonical `AgentProvider` case token
- Linux and macOS logical paths and the canonical discovery file pattern
- XDG/home expansion behavior and resolved-path session identity behavior
- Honest ingestion and quota-signal coverage (`local-parser`, `api-backed`, or
  `unavailable`)
- A user-facing coverage note used by Settings and onboarding

Linux consumes the manifest directly through `providerPathRegistry.ts`.
`scripts/generate-provider-ingestion-catalog.mjs` emits the Swift contract into
the existing `OpenBurnBarParserSupport` leaf; both `AgentProvider.logDirectory`
and `AgentProviderLogDiscovery` use that generated contract. `--check` fails on
generated drift without growing the LogParsers target past its membership
ceiling.

The catalog is checked against the committed macOS/core sources by
`providerPathRegistry.swiftParity.test.ts` and
`ProviderIngestionContractTests.swift`:

- `AgentProvider.swift` must expose exactly the same 33 case tokens.
- generated Swift must contain every row's platform paths, file pattern,
  aliases, coverage, and quota declaration.
- `ParserRegistry.swift` must expose exactly the 29 local parser registrations
  represented by `local-parser` rows.
- `AgentProvider.quotaSignalProviders` must match the 19 quota-capable rows.
- shared golden vectors pin provider identity, RFC3339 timestamps,
  deterministic dedup IDs, billed-token normalization, USD cost preservation,
  account partitioning, and quota capability.
- The four canonical providers without a local parser remain explicit:
  `OpenAI`, `OpenBurnBar`, `DeepSeek`, and `MiMo` are API/native-ledger backed.
  OpenClaude now uses the Claude-compatible project JSONL parser and OMP uses
  the Pi-compatible local JSONL parser.

No parser implementation is invented for a provider that is absent from the
canonical registry.

## User-facing behavior

Settings -> Engine Room shows a coverage summary (`29 local parsers, 4
API-backed sources, 0 unavailable local sources`) and labels every provider
path with its source state. Onboarding repeats the same count and explains that
API-backed and unavailable sources are not local scans. This prevents a path
row from implying that a parser exists merely because the provider is in the
canonical enum.

## Validation

Focused command from `apps/linux-desktop`:

```text
npx vitest run src/providerPathRegistry.test.ts src/providerPathRegistry.swiftParity.test.ts src/surfaces/settings/SettingsSurface.test.tsx --reporter=dot
node ../../scripts/generate-provider-ingestion-catalog.mjs --check
swift build --package-path ../../OpenBurnBarCore --target OpenBurnBarLogParsers
```

The provider contract subset is 12 TypeScript assertions. The complete command
also includes the Settings surface regression suite.

The provider path tests also cover default and custom `XDG_CONFIG_HOME` /
`XDG_DATA_HOME` resolution for all 33 rows.

## Remaining parity work

The source contract is closed. The following installed/runtime evidence remains
open and must stay visible in the parity ledger:

1. Run representative real provider logs through installed macOS and Linux
   candidates and retain signed scan receipts. Source normalization is pinned;
   this step proves packaging, permissions, file watching, and runtime I/O.
2. Exercise empty, malformed, permission-denied, rotation/symlink, migration,
   and multi-account cases in installed environments.
3. Prove live API/quota aggregation, recount, projections, cloud mirror, and account
   switching against the same candidate release and installed environments.
4. Run the OpenClaude parser against installed project transcripts and retain a
   signed scan receipt. The source fixture proves the Claude-compatible shape;
   packaging, permissions, rotation, and real-account behavior remain live gates.

## QA checklist

- [x] 33 canonical provider cases have one and only one catalog row.
- [x] 29 `ParserRegistry` registrations have `local-parser` rows.
- [x] API-backed providers are not shown as local parsers.
- [x] Providers without a parser show an explicit unavailable state (none in the
  current 33-provider catalog).
- [x] Linux conditional VS Code/Windsurf/Warp paths are checked.
- [x] macOS and Linux discovery and parser log-directory access share one
  generated path/pattern contract.
- [x] Quota declarations and golden identity/timestamp/dedup/token/cost vectors
  are checked against the same manifest.
- [x] Default and custom XDG path expansion is table-tested.
- [x] Settings renders the summary and per-row coverage labels.
- [x] Onboarding repeats the coverage summary and source boundary.
- [ ] Installed Linux runtime scans representative provider fixtures.
- [x] macOS/Linux normalized source-contract corpus is exact.
- [ ] Seven-environment release matrix and real account/quota evidence pass.
