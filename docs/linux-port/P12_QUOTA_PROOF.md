# P-12 Linux Quota Proof

P-12 is a Tier B installed-product proof. Source tests are useful, but cannot
close it. Each supported Linux environment must run the signed candidate in a
real desktop session and preserve the raw daemon, interaction, accessibility,
and screenshot artifacts under its environment-specific P-12 evidence root.

The proof requires:

- provider quota buckets with bounded percentages, reset windows, and states;
- provider IDs, parser source IDs, and aliases matching
  `contracts/provider-ingestion-catalog.json`;
- four independently hashed catalog states: initial live data, stale retained
  data after refresh failure, a successful fresh retry that may update values,
  and a post-restart readback matching the retry;
- a raw authenticated AF_UNIX `daemon.quota.signals.recent` transcript whose
  source IDs and bucket values are hash-bound to every live catalog snapshot;
- initial and retry requests through the installed loopback HTTP gateway to a
  bounded local upstream, with distinct quota headers bound to persisted daemon
  signal IDs rather than a hand-authored signal file;
- daemon failover mode read, mutation, readback, rollback, and rollback
  readback;
- application restart with a new PID and byte-identical quota persistence;
- live and stale-state AT-SPI semantics plus distinct, decodable, nonblank PNGs;
- a valid Ed25519 installed-manifest signature, exact candidate hashes, and
  the requested OS, architecture, desktop, and display-server identity.

`materialize-p12-quota-session.mjs` copies raw probe output without rewriting
it, binds every file by SHA-256, and validates the complete session before it
writes the report. `capture-p12-quota-proof.mjs` then reopens that report and
emits the only artifact registered under role
`p-12-installed-quota-proof`. The product validator replays the entire
validation; booleans in a producer report are never accepted as proof.

Every transition event carries the corresponding catalog SHA-256, and the four
read events also match the catalog capture timestamp exactly.

The validator deliberately fails on stale captures, changed bytes, reused
screenshots, forged signatures, fixture desktops, canonical-provider drift,
missing windows, false retry/rollback sequences, or restart claims without a
PID transition.

`run-p12-native-quota-probes.mjs` is the only supported raw producer. It starts
with an isolated support directory, routes the installed gateway to a bounded
loopback upstream, and generates quota signals through normal provider traffic.
It never creates or edits `quota-signals.jsonl`. The runner interrupts and
restarts the user daemon, exercises retry and failover rollback, restarts the
installed desktop, and writes the exact raw files consumed by the materializer.
