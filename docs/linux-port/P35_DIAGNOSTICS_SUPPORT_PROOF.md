# P-35 Diagnostics and Support installed proof

P-35 is credited only from the signed installed Linux package and the live Tauri Support route. Browser fixtures, source inspection, synthetic accessibility trees, direct construction of a diagnostics bundle, and uninstalled binaries do not count.

The production probe performs the following bounded workflow:

1. Verify the selected signed package candidate and root-owned `/usr/bin/openburnbar-linux-desktop` plus `/usr/bin/openburnbar-daemon` identities.
2. Launch `openburnbar://support` with fixture mode disabled and capture the live metadata-only preview.
3. Activate **Export redacted diagnostics**, accept the native save dialog in an empty owner-only selected directory, and require a complete atomic `0600` regular JSON file with no partial artifacts.
4. Compare shell, daemon, package-manager, architecture, desktop, session, display-server, and runtime facts against the signed installed candidate and requested environment.
5. Scan the structural bundle for planted credentials, auth material, provider payloads, session content, workspace data, and absolute user paths. Exclusion labels are allowed; excluded data is not.
6. Stop the real user daemon, reload Support, invoke **Reconnect** exactly once, and require the UI to remain degraded within five seconds. No optimistic success is accepted.
7. Restart the daemon, reconnect again, and require the accessible **Connected** recovery state.
8. Restore the exact prior daemon active/inactive state, installed desktop process set, and isolated shell state.

Four distinct screenshots and live AT-SPI summaries bind preview, exported, degraded, and recovered states. The session is bound to the release HEAD, candidate run, artifact digest, package version, installed manifest/signature, a fresh random nonce, and a derived one-use challenge. Materialization re-hashes every copied byte; proof capture rejects stale or replayed sessions.

The standalone files are intentionally isolated from shared registry, workflow, preflight, and audit modules. `product-validators/P-35.mjs` is the only product-validation adapter for the proof role.

Focused verification:

```bash
node --test scripts/linux-port/p35-diagnostics-support-proof.test.mjs scripts/linux-port/ownership-tests/P-35.test.mjs
node --check scripts/linux-port/run-p35-native-diagnostics-probes.mjs
node --check scripts/linux-port/lib/p35-diagnostics-support-proof.mjs
```
