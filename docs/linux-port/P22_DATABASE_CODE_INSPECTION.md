# P-22 Database Code Inspection

The Linux Database route now exposes a bounded, read-only inspection path for
the daemon-owned project code index. This is an implementation slice, not a
parity certification receipt.

## Contract

- Search calls `daemon.code.search` with `query`, optional `projectPath`, and a
  result limit clamped to 1–50.
- Context packs call `daemon.code.context_pack` with the same query scope,
  result limit, and `maxBytes` clamped to 1,024–24,000.
- The Rust Tauri commands reject blank queries and return daemon errors to the
  renderer. They do not substitute fixture rows when the live daemon or index
  is unavailable.
- The TypeScript bridge maps the canonical search/context response, including
  degradation metadata and the daemon trust signal. The renderer treats every
  snippet/context pack as untrusted source data and displays that warning next
  to the result.

## UI behavior

Atlas and System modes share the same search surface. Results are paginated in
ten-row pages after the daemon-bound result limit is applied. The context-pack
action is disabled when the packaged shell does not expose the canonical
method; no invented RPC or local cache is used.

Fixture mode contains deterministic snippets for development screenshots and
component tests only. Production fixture exports throw, so a packaged build
cannot accidentally claim live database inspection from fixture data.

## Verification

- `src/bridgeRpcContract.test.ts` checks canonical RPC IDs and command wiring.
- `src/bridgeRpcBehavior.test.ts` checks request shape, blank-query rejection,
  response mapping, and limit/max-byte clamping.
- `src/state/databaseStore.test.ts` checks fail-closed behavior when optional
  bridge methods are missing and store-side limit clamping.
- `src/surfaces/database/DatabaseSurface.test.tsx` checks result rendering,
  the untrusted-source warning, pagination, and context-pack invocation.
- Rust unit coverage checks query rejection and read bounds.

Installed parity still requires a current-head daemon with a configured code
index, a signed Linux package, and receipts on every support-matrix row. Those
environment proofs remain outside this source implementation slice.
