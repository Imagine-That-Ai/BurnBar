# Endpoint Authorization Matrix

The machine-readable source of truth is `functions/src/security/endpointAuthorizationMatrix.ts`, backed by the generated catalog in `functions/src/security/endpointAuthorizationCatalog.generated.ts`.

Each exported Cloud Function declares:

- trigger type (`callable`, `http`, `firestore-trigger`, `scheduled`, `provider-webhook`)
- authentication method
- App Check posture
- tenant source
- client-controlled object identifiers
- ownership check
- typed `bolaCoverage[]` references (not legacy `negativeBolaTest` strings)

## BOLA coverage kinds

| Kind | Purpose |
|------|---------|
| `runtime-cross-user` | Vitest exercises cross-tenant denial at the handler trust boundary |
| `static-high-risk-wiring` | Source guard for `enforceHighRiskOwnerAction` on destructive callables |
| `firestore-rules` | Client Firestore surface covered by rules tests (requires `clientFirestoreSurface`) |
| `auth-only` | Callable has no client object ids; unauthenticated rejection is sufficient |
| `platform-trigger` | Scheduled / Firestore / webhook triggers are not client-callable |
| `not-applicable-public` | Public health or bootstrap endpoints without tenant objects |

Runtime tests live under `functions/src/__tests__/bola/`. Shared harness: `callableBolaHarness.ts` (includes `expectCallableDenial`, `tier2CallableProof`, `snapshotTenantPaths`, `expectTenantPathsUnchanged`). Regression guard: `callableHarness.bola.test.ts`. CI validators: `bolaCoverage.test.ts`.

### Tier-2 victim seeding

Object-id callables use `tier2CallableProof`: seed Bob's tenant via `bolaVictimSeeds.generated.ts`, invoke as Alice, assert Bob's paths are unchanged. Handlers with explicit ownership checks must throw (`expectedOutcome: "throws"`); auth-scoped handlers may succeed while victim isolation still holds (`expectedOutcome: "no-side-effect"`).

P0 endpoints (`BOLA_STRICT_CODE_ENDPOINTS` in the harness) require strict denial codes — not generic `invalid-argument`. Regenerate seeds after catalog changes:

```sh
node functions/scripts/generate-bola-victim-seeds.mjs
```

Auth-scoped handlers (tenant from `request.auth.uid` only) use `expectedOutcome: "no-side-effect"` — seed the victim tenant, invoke as attacker, assert victim paths unchanged. Object-id handlers with explicit ownership checks use `expectedOutcome: "throws"` with a concrete `expectedCode`.

## Regenerating the catalog

After adding exports to `functions/src/index.ts`, refresh the generated catalog and BOLA scaffolds:

```sh
node functions/scripts/generate-endpoint-catalog.mjs
node functions/scripts/sync-bola-test-payloads.mjs
node functions/scripts/sync-bola-firestore-mocks.mjs
```

Do not hand-edit `endpointAuthorizationCatalog.generated.ts`; override fields via the generator's catalog merge tables.

## Running security tests

```sh
npm --prefix functions run test:security
```

This runs matrix parity, BOLA coverage validators, per-endpoint BOLA runtime suites, and existing security guard tests.
