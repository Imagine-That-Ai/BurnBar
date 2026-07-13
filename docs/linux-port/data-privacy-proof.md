# P-40 Data and Privacy Proof

P-40 is the Linux certification contract for the macOS Data & Privacy control
center. It keeps the evidence boundary explicit: the checked-in producer emits
metadata-only `contract-fixture` evidence, never production records, secrets,
prompts, paths, or account identifiers. A fixture proof is useful for testing
the contract and workflow wiring, but it is not a live parity receipt.

## Required Surface

The proof covers the twelve domains in `packages/data-domains/registry.json`
and binds each domain's encryption tier, retention policy, and supported
actions to the current checkout. It also covers these control families:

| Family | Required behavior |
| --- | --- |
| Export | Preview, cancel without writing, scoped selection, sealed-facet protection, redaction, and an audit event. |
| Deletion | Explicit local/account scope, typed confirmation, durable intent, server completion receipt, and retry after partial failure. |
| Retention | Rolling expiry, until-deleted and until-revoked lifetimes, and append-only audit preservation. |
| Recovery | Setup and confirmation, failure-closed recovery, and no raw recovery key transmission. |
| Consent | Telemetry and cloud-sync default off, persisted choices, and no emission/upload without consent. |
| Panic | Sync-only and all-access scopes, typed confirmation, and an audit record. |
| Redaction | Diagnostics, exports, support bundles, telemetry, paths, PII, and secrets remain redacted. |

The case matrix additionally covers offline queueing, locked keyrings,
retention expiry, account/local deletion, partial failure, and panic recovery.

## Candidate Binding

Every proof is bound to:

- the exact `P-40` requirement and support environment;
- the current Git commit and successful release candidate run/digest;
- the current domain registry and all privacy source-contract hashes; and
- the registered `feature.data-privacy-proof` artifact.

The validator re-reads every source file and registry from the checkout. It
rejects stale hashes, candidate substitution, environment substitution,
symlinked evidence roots, unsafe control mutations, and sensitive evidence.

## Promotion Boundary

`mode: fixture` and `evidenceOrigin: contract-fixture` are intentional. The
proof must remain non-promotable until each required Linux environment supplies
live installed evidence for export, deletion, retention, recovery, consent,
panic, and redaction. Do not convert fixture fields to `live` or add receipts by
hand; run the candidate-bound workflow on the target installed package.

