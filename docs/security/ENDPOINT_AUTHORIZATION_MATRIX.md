# Endpoint Authorization Matrix

The machine-readable source of truth is `functions/src/security/endpointAuthorizationMatrix.ts`, backed by the generated catalog in `functions/src/security/endpointAuthorizationCatalog.generated.ts`.

Each exported Cloud Function declares:

- trigger type (`callable`, `http`, `firestore-trigger`, `pubsub-trigger`, `scheduled`, `provider-webhook`, `task-queue`)
- authentication method
- App Check posture
- tenant source
- client-controlled object identifiers
- ownership check
- typed `bolaCoverage[]` references (not legacy `negativeBolaTest` strings)

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

Do not hand-edit `endpointAuthorizationCatalog.generated.ts`; override fields via the generator's catalog merge tables. `handlerModule` is derived by the generator from the file that actually defines each export (the wrapper-name literal wins over a bare `export` re-export helper), so stale module paths self-correct on regen.

## Callable rate-policy registry

Every catalog callable (`trigger: "callable"`) must declare a rate policy in
`packages/functions-shared/src/callables/callableRatePolicy.ts`
(`CALLABLE_RATE_POLICIES`). `wrapCallableHandler` / `onCallProduction` resolve
the entry by exported name at module load — a callable with no entry throws at
definition time, so an undeclared endpoint can never run unbounded.

Policy kinds:

| Kind               | Meaning                                                                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `limited`          | Central per-uid limiter (`checkCallablePolicyRateLimit`) enforces the tier's burst + sustained windows before the handler runs.                      |
| `handler-enforced` | The handler already calls a bespoke volume limiter (e.g. `checkVoIPCallRateLimit`); the wrapper adds no second limiter. Entries name the checker + module and are inventory-tested. |
| `exempt`           | `read-only` (no writes besides logging), `bulk-sync` (bounded by a per-request batch cap, not a counter doc — see the entry's reason), `per-object-bounded` (each call is capped against a server-owned object whose creation is itself rate-limited — e.g. mission claim/status/event appends, capped by `MAX_MISSION_EVENT_SEQUENCE`), or `admin-only`. |

Tier defaults live in `CALLABLE_RATE_TIERS` (`external-side-effect`,
`destructive`, `security`, `mutation`); a `limited` entry may override
`limits` (e.g. `submitBugReport` uses 3 per 10 min / 10 per day).

Rate-limit rejections are `resource-exhausted` and are logged as a structured
`callable_rate_limited` warn event instead of going to Sentry as exceptions —
expected control flow, not an incident. Both windows are incremented in a
single Firestore transaction, so a sustained-window rejection cannot
half-advance the burst window.

The registry is asserted by `functions/src/__tests__/callableRatePolicyInventory.test.ts`:
keys match the catalog in both directions, reasons are real one-line justifications,
handler-enforced modules import and call their checker, and every callable
passes its exact exported name to the wrapper.

## Running security tests

```sh
npm --prefix functions run test:security
```

This runs matrix parity, BOLA coverage validators, per-endpoint BOLA runtime suites, and existing security guard tests.
