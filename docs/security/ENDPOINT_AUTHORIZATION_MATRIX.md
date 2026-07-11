# Endpoint Authorization Matrix

The machine-readable source of truth is `functions/src/security/endpointAuthorizationMatrix.ts`, backed by the generated catalog in `functions/src/security/endpointAuthorizationCatalog.generated.ts`.

Each exported Cloud Function declares:

- trigger type (`callable`, `http`, `firestore-trigger`, `scheduled`, `provider-webhook`, `task-queue`)
- authentication method
- App Check posture
- lower-trust desktop policy
- tenant source
- client-controlled object identifiers
- ownership check
- typed `bolaCoverage[]` references (not legacy `negativeBolaTest` strings)

## Lower-trust desktop policy

Every App Check-required callable is classified independently of Firebase's
token-validity decision. `wrapCallableHandler` enforces this catalog entry before
the handler runs, so a valid custom Linux or Windows App Check token is not an
authorization grant by itself. Unclassified app IDs and missing catalog rows
fail closed. Standard browser trust is also explicit: only IDs in
`APP_CHECK_STANDARD_WEB_APP_IDS` classify as Web reCAPTCHA principals. A generic
Firebase `:web:` ID is never promoted by syntax alone.

| Policy | Meaning |
| --- | --- |
| `deny` | Apple, Android, and Web App Check only; lower-trust desktop tokens are rejected. |
| `linux-low-risk` | Linux may enter an audited owner-scoped encrypted/read-only/bounded operation. Windows remains denied. |
| `desktop-attestation-binding` | Linux or Windows may bind the live App Check ID to the authenticated principal. |
| `desktop-nonce-bootstrap` | Linux or Windows may request the single-use nonce required by the later step-up. |
| `desktop-trusted-device-step-up` | Linux or Windows may enter only a source-wired handler whose exact `enforceHighRiskOwnerAction` action kind is catalog-validated; the shared helper runtime-tests nonce consumption, trusted-device proof, and fail-closed audit persistence. |
| `not-applicable` | The endpoint does not require App Check, such as a platform trigger or the authenticated token-mint bootstrap. |

The current Linux surface contains 30 low-risk callables, 15 trusted-device
step-up callables, two prerequisites, and 76 deny-by-default callables. Change
those sets only through `LOWER_TRUST_DESKTOP_POLICY_OVERRIDES` in the generator;
the matrix and AST source-wiring tests enforce their cardinality and invariants.

## BOLA coverage kinds

| Kind                      | Purpose                                                                             |
| ------------------------- | ----------------------------------------------------------------------------------- |
| `runtime-cross-user`      | Vitest exercises cross-tenant denial at the handler trust boundary                  |
| `static-high-risk-wiring` | Source guard for `enforceHighRiskOwnerAction` on destructive callables              |
| `firestore-rules`         | Client Firestore surface covered by rules tests (requires `clientFirestoreSurface`) |
| `auth-only`               | Callable has no client object ids; unauthenticated rejection is sufficient          |
| `platform-trigger`        | Scheduled / Firestore / webhook triggers are not client-callable                    |
| `not-applicable-public`   | Public health or bootstrap endpoints without tenant objects                         |

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
