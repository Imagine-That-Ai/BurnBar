# Drive Hermes iroh transport to production

> **Current state (2026-05-17):** this handoff is no longer a fresh Phase A
> start from commit `072a96070`. Phase A and Phase B are recorded green in
> [`HERMES_IROH_TRANSPORT.md`](HERMES_IROH_TRANSPORT.md), production Firestore
> rules and hosted relay Remote Config are live, physical iOS and Android
> selected-model hosted-relay proofs are green, and the immediate PR-harness
> blocker on branch `chore/router-brand-coherent-rail` is repaired locally as a
> provider-router/keychain regression cluster. The latest local repair keeps
> provider-family mode pinned to the catalog vendor only when that vendor can
> actually route the requested model, preserves fallback to a credentialed
> same-family provider, and restores provider keychain overwrite semantics so
> stale login-keychain metadata is deleted instead of preserved. Local
> verification: `cd OpenBurnBarDaemon && swift test` passes 261 tests.
>
> The rollout is still **not production complete**. The remaining hard gates
> are the renewed different-network/cellular iPhone Gate C/D sequence, a clean
> pushed CI run on the repaired branch, Phase E TestFlight/internal soak, and
> explicit approvals for any production deploy, TestFlight submission, Remote
> Config percentage increase, hosted-relay spend, or WSS retirement action.

You are taking over the OpenBurnBar Hermes Realtime Relay migration from Cloud Run + WSS to **iroh peer-to-peer QUIC**. The transport foundation, error handling, schema, rules, tests, hosted-relay plumbing, monitoring rollup, and cross-platform smoke paths are already in place on branch `chore/router-brand-coherent-rail`. Your job is to drive it from the current state above all the way to "users on TestFlight are routing real Hermes chat completions over iroh, with monitoring and a rollback plan."

This is a **multi-phase production rollout**. Do not skip phases. Each phase has a hard gate at the bottom — do not advance until it's green. If you get blocked at a gate, surface the blocker to the user with a concrete unblock request rather than working around it.

---

## Working agreements

- **Branch:** `chore/router-brand-coherent-rail` is the working branch. Open a PR from it into `main` when CI is green; do not push directly to `main` and do not merge without explicit user approval.
- **Commits:** small, atomic, one logical change each. Conventional Commits style (`fix(scope): …`, `chore(scope): …`, `feat(scope): …`). Co-author tag the bot.
- **No silent fallbacks.** If a step fails, diagnose before moving on. Don't disable a failing test, don't `|| true` a failing script, don't comment out a broken assertion. Surface the failure to the user.
- **No destructive ops without confirmation.** Specifically: `firebase deploy` to production, `gh pr merge`, `git push --force`, `gcloud` writes that touch the prod project, anything touching billing, anything that costs money (n0 hosted relay provisioning at $200/mo). Always ask first.
- **Read before you write.** Use `Read`, `Grep`, `Glob`, `LS`. Never propose changes to files you haven't read in this session.
- **Document as you go.** Update `docs/HERMES_IROH_TRANSPORT.md` and `CHANGELOG.md` whenever a phase closes. Add operational runbook content under `docs/runbooks/` for anything an oncall would need at 2am.

---

## Mission context (read this once, then proceed)

Files that define the current state (read these before doing anything):

- `crates/openburnbar-iroh/src/lib.rs` — UniFFI surface (8 functions) pinned to `iroh = "0.91"`.
- `crates/openburnbar-iroh/Cargo.toml` + `Cargo.lock` — locked dep graph.
- `scripts/build-iroh-xcframework.sh` — recipe that produces `Vendor/OpenBurnBarIroh.xcframework`.
- `.github/workflows/iroh-xcframework.yml` — CI that runs the recipe.
- `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/` — Swift transport layer (transport, codec, pairing signatures, audit logger, FFI bridge).
- `AgentLens/Services/IrohRelay/` — Mac host (`HermesIrohRelayHostClient`, fanout, key publisher, request handler).
- `OpenBurnBarMobile/Services/IrohRelay/` — iOS dialer (`HermesIrohRelayTransport`, public key reader, pairing directory reader).
- `OpenBurnBarMobile/Services/HermesService.swift` — `HermesCompositeRelayTransport` (iroh → WSS → Firestore cascade, gated by `UserDefaults` key `hermes_iroh_transport_enabled`).
- `functions/src/types.ts` — schema (`IrohPairingRecordDoc`, `IrohPairingPublicKeyDoc`, `IrohTransportAuditEventDoc`, AAD prefix `openburnbar.iroh.pairing.v1`).
- `firestore.rules` — gates `iroh_pairing/*`, `iroh_pairing_keys/*`, `iroh_audit_events/*`.
- `docs/HERMES_IROH_TRANSPORT.md` — architecture overview.
- `docs/HERMES_IROH_RETIREMENT.md` — Phase 7 retirement gates.
- `scripts/deploy-iroh-relay.sh` — Firestore rules deploy with safety gates.
- `scripts/cutover-n0-hosted-relay.sh` — n0 hosted relay provisioning + Remote Config publish.
- Commit `072a96070` (most recent) — audit-pass log of every issue and fix.

Verified state at original handoff:
- 34/34 SwiftPM tests green on macOS arm64.
- `cargo check` clean for the Rust crate on the host.
- iOS Rust targets, xcframework build, both Xcode app builds, `tsc` on `functions/`, real Mac↔iOS dial, deploys, monitoring — **none of these had run yet**.

Verified state now:
- Phase A and Phase B are green in `docs/HERMES_IROH_TRANSPORT.md`.
- Production Firestore rules, hosted relay URL Remote Config, and daily
  monitoring rollup are live.
- Same-LAN physical-iPhone hosted-relay validation has a historical 10-run
  clean streak, but the later topology preflight proved the phone was still on
  Wi-Fi. Formal Gate C/D still needs a renewed different-network/cellular run.
- Physical iOS and Android selected-model hosted-relay smoke tests are green
  for `minimax-m2.7-highspeed`, with explicit requested-model fidelity and no
  silent reroute to a default GPT model.
- Local daemon verification after the provider-router/keychain repair:
  `cd OpenBurnBarDaemon && swift test` passes 261 tests.

Feature flag (off by default): `SettingsManager.hermesIrohTransportEnabled` on Mac, `UserDefaults` key `hermes_iroh_transport_enabled` on iOS. Until this flag is on, the iroh code paths are dormant.

---

## Phase A — Prove the foundation compiles everywhere

**Goal:** every artifact the production pipeline depends on actually builds.

Coding work:
1. Run `cargo check -p openburnbar-iroh` and `cargo check -p openburnbar-iroh --release`. Expect: clean.
2. Cross-compile the Rust crate for the Apple targets the xcframework recipe packages:
   - Install targets: `rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`. If `rustup` isn't on the system, the user is on Homebrew Rust — install rustup via `brew install rustup-init && rustup-init -y --default-toolchain stable` and re-source `~/.cargo/env`.
   - For each target: `cd crates/openburnbar-iroh && cargo build --target <target> --release`. If any target fails to cross-compile, that's a real iroh-0.91 portability bug — diagnose and report. Do not paper over with feature flags.
3. Build the xcframework: `./scripts/build-iroh-xcframework.sh`. Expect outputs at `Vendor/OpenBurnBarIroh.xcframework/` and `OpenBurnBarCore/Sources/OpenBurnBarIroh/Generated/openburnbar_iroh.swift`. Inspect with `file Vendor/OpenBurnBarIroh.xcframework/*/libopenburnbar_iroh.a` — confirm Mach-O arm64 + arm64 simulator + x86_64 simulator slices.
4. Confirm `OpenBurnBarCore/Package.swift` references the xcframework binary correctly. If not, wire it in (the path is `Vendor/OpenBurnBarIroh.xcframework`; the target name is `OpenBurnBarIrohFFI`). Re-run `swift build` in `OpenBurnBarCore/` — the `#if canImport(OpenBurnBarIrohFFI)` branch should now compile.
5. Build both Xcode targets:
   - `cd AgentLens` → `xcodegen generate` if `project.yml` is the source → `xcodebuild -project AgentLens.xcodeproj -scheme AgentLens -destination 'platform=macOS' clean build` (substitute real scheme name). Resolve every error.
   - Same for `OpenBurnBarMobile.xcodeproj` with `-destination 'generic/platform=iOS'` and `'platform=iOS Simulator,name=iPhone 17 Pro Max'`.
6. Run `cd functions && npm ci && npx tsc --noEmit`. Resolve every type error introduced by `IrohPairingPublicKeyDoc` and the AAD prefix change.

Non-coding work:
- Push the branch to origin (`git push -u origin chore/router-brand-coherent-rail`) and watch the `OpenBurnBarIroh xcframework` workflow run on GitHub. URL: `https://github.com/Imagine-That-Ai/BurnBar/actions`. Wait for green. If it fails, the failure mode tells you whether it's a Rust portability issue or a recipe issue — fix and re-push.

**Gate A:** local `cargo check` ✓, local cross-compile to all packaged Apple targets ✓, xcframework artifacts exist on disk ✓, `xcodebuild` of both apps ✓, `tsc --noEmit` clean ✓, CI workflow green on the latest commit ✓. Do not advance until all six.

---

## Phase B — Wire the secrets and infrastructure

**Goal:** every credential and external system the production cascade depends on exists, is reachable, and is documented.

Non-coding work (you'll need to coordinate with the user for any credential you don't already have):
1. **`IROH_SERVICES_API_SECRET`** — the user already has this at `.secrets/iroh-services.env` locally (gitignored, 600 perms). Verify: `ls -la .secrets/iroh-services.env` and `source scripts/ci/load-iroh-services-secret.sh && env | grep IROH_SERVICES_API_SECRET | wc -c` (should be > 0). On GitHub: confirm the secret is set at `https://github.com/Imagine-That-Ai/BurnBar/settings/secrets/actions` under the name `IROH_SERVICES_API_SECRET`. If missing, ask the user to add it.
2. **Firebase project** — confirm which project ID is production (likely `openburnbar` or similar). `firebase projects:list`. Confirm the user is logged in as the right principal: `firebase login:list`.
3. **Apple Developer / TestFlight** — confirm the team ID, the AgentLens bundle ID, the OpenBurnBarMobile bundle ID, and that the user has admin rights in App Store Connect.
4. **n0 services account** — confirm the hosted relay tier is provisioned (or that there's a budget approval to provision it at ~$200/mo). The script that provisions is `scripts/cutover-n0-hosted-relay.sh provision`. Don't run it yet — Phase D.
5. **Firebase Remote Config** — confirm access to the Remote Config console for the production project. Phase D writes the `hermes_iroh_hosted_relay_url` parameter there.
6. **Monitoring** — confirm where iroh audit events will surface. They land in Firestore at `users/{uid}/iroh_audit_events/*`. There's no dashboard yet. Decide with the user: BigQuery export + Looker Studio dashboard, or a Cloud Run scheduled job that rolls up daily, or a simple Firestore query in the AgentLens audit log UI. **Build whichever the user picks before Phase E.** Do not skip this — Phase 7 retirement is gated on telemetry showing 0 WSS fallbacks for 14 days.

**Gate B:** every credential above is present and verified, monitoring solution is decided and built, and `docs/runbooks/iroh-secrets.md` documents where each secret lives and how to rotate it.

---

## Phase C — End-to-end dev round-trip

**Goal:** flip the flag in a dev build and watch a real chat completion travel over iroh.

Coding work:
1. Spot-check the wiring by reading every `#if canImport(OpenBurnBarIrohFFI)` branch in the package. Make sure each one actually links the right symbol after Phase A.
2. Add a debug-build-only assertion in `HermesIrohRelayHostClient.start` and `HermesIrohRelayTransport.transport()` that the transport returned is `IrohXcframeworkTransport`, not `LoopbackIrohRelayTransport`. The loopback transport works only same-process — if a real iOS device gets it, the cascade silently degrades and you'll spend hours debugging. The assertion catches that misconfiguration at startup.
3. Test app: ensure `AgentLens` has a debug menu (or build setting) that toggles `hermesIrohTransportEnabled` without going through Settings UI, so QA doesn't need to navigate the live UI to flip the flag.

Non-coding work:
1. Sign in to the same Firebase user on the dev Mac and a dev iOS device (or simulator paired with the Mac on the same LAN).
2. Mac: enable Remote Relay, enable "Use iroh peer-to-peer transport," confirm a Firestore write to `users/{uid}/iroh_pairing_keys/host` and `users/{uid}/iroh_pairing/{connectionId}`. Verify the schema matches `IrohPairingPublicKeyDoc` and `IrohPairingRecordDoc`.
3. iOS: enable the same flag (UserDefaults key `hermes_iroh_transport_enabled`). Send a Hermes chat completion. Tail `users/{uid}/iroh_audit_events/*` in the Firestore console.
4. Expected events in order: `iroh_pairing_published` (Mac, at start), `iroh_pairing_verified` (iOS, on first dial), `iroh_stream_opened`, `iroh_stream_closed`. If you see `iroh_fallback_to_wss`, capture the `detail.error` field and diagnose — that's a real failure mode the design is supposed to prevent.
5. Repeat the test with the Mac and iOS device on different networks (Mac on WiFi, iPhone on cellular) to confirm iroh's NAT traversal works in the real world, not just on LAN.
6. Verify the 5s connect timeout: temporarily edit the Mac's iroh secret in Keychain to break the dial. iOS should fall back to WSS within 5s, not 60-120s. After verifying, restore the Keychain entry.

**Gate C:** at least 10 consecutive Mac↔iOS chat completions complete over iroh across at least 2 network topologies (same LAN + different ISPs), with `iroh_audit_events` showing the expected 4-event sequence for each. Failure rate < 5%. Capture screenshots and `iroh_audit_events` exports under `docs/runbooks/iroh-dev-validation/`.

---

## Phase D — Production infrastructure

**Goal:** the production Firestore, Cloud Functions, and hosted relay are ready to serve real users.

Non-coding work (each step requires explicit user approval before execution):
1. **Deploy Firestore rules** via `./scripts/deploy-iroh-relay.sh` (the script has dry-run support — always run `--dry-run` first, show diff to user, then real deploy). Rules add `iroh_pairing`, `iroh_pairing_keys`, `iroh_audit_events` collections.
2. **Deploy Cloud Functions** if `functions/src/index.ts` references any of the new types: `cd functions && npm run build && firebase deploy --only functions:<specific-functions>`. Do NOT deploy all functions blindly.
3. **Provision n0 hosted relay** via `./scripts/cutover-n0-hosted-relay.sh provision`. Capture the relay URL. Cost: ~$200/mo. Get user signoff.
4. **Publish relay URL** to Firebase Remote Config: `./scripts/cutover-n0-hosted-relay.sh publish <url>`. Verify the parameter `hermes_iroh_hosted_relay_url` is live in the production Remote Config.
5. **Verify rules** are live: `firebase firestore:rules:get` (or equivalent) should show the deployed rules. Hit the new collections with a curl-based smoke test using a test user's ID token.

**Gate D:** rules deployed, hosted relay reachable from both the dev Mac and the dev iOS device, Remote Config parameter set. Rerun the Phase C end-to-end test using the hosted relay URL — events should still flow cleanly, with the `detail.relayUrl` field on `iroh_pairing_published` matching the hosted URL.

---

## Phase E — TestFlight rollout

**Goal:** real internal testers exercise iroh on real iPhones and real iPads.

Coding work:
- Bump version numbers in both Xcode projects (or the user's release script). Tag the release commit.
- Generate release notes that explicitly call out "experimental iroh transport — off by default, can be enabled in Settings → Remote Relay."

Non-coding work:
1. Archive AgentLens for the Mac App Store (or DMG direct distribution, whichever the user uses). Notarize. Upload.
2. Archive OpenBurnBarMobile: `xcodebuild archive -scheme OpenBurnBarMobile -configuration Release -archivePath build/OpenBurnBarMobile.xcarchive` then upload via Transporter or `xcrun altool`. Submit to TestFlight internal testing.
3. Recruit 5-10 internal testers (coordinate with user — they'll have the list). Send TestFlight invites.
4. Run a 7-day soak with the flag **off by default** for everyone except the internal testers. Internal testers flip the flag on per-device.
5. Watch `iroh_audit_events` in real time. Daily dashboard check: success rate, fallback rate, p50/p95/p99 RTT. Track in `docs/runbooks/iroh-soak-week-1.md`.

**Gate E:** ≥7 days of internal soak with ≥95% iroh success rate across all testers, ≤5% fallback-to-WSS rate, no crashes traceable to iroh, no `iroh_pairing_rejected` events (those mean the verifier key publication race never happens). Any regression → fix → restart the 7-day clock.

---

## Phase F — Public rollout

**Goal:** the iroh flag is on by default for new users, gradually rolled out to existing users.

Coding work:
- Change the iOS default for `hermes_iroh_transport_enabled` from `false` to `true` **inside a Firebase Remote Config-gated default** so you can dial it back without shipping a new build. The pattern: `UserDefaults.standard.bool(forKey:)` returns false if unset; introduce a `RemoteConfig.shared.defaultValue("hermes_iroh_default_enabled")` shim with `false` as the local default, and have the composite cascade read `userDefault OR remoteConfigDefault`.
- Same shim on Mac (`SettingsManager` reads from Remote Config when the user hasn't explicitly toggled).

Non-coding work:
1. Production release: same archive/upload flow as Phase E, but submit to the App Store for review. Use the Remote Config default = `false` so the rollout is purely server-controlled after the binary is approved.
2. Once approved and live in the store: in Remote Config, set `hermes_iroh_default_enabled` to a **percentage rollout** — start at 5%, watch metrics for 24h, advance to 25%, 50%, 100% with 24h-72h between each step. Roll back instantly by setting the percentage back to 0 if metrics regress.

**Gate F:** ≥99% of opted-in users complete chat completions over iroh, ≤1% fall back to WSS, p95 RTT improves over the WSS baseline (or at least doesn't regress significantly). Cost telemetry shows the expected $45/mo Cloud Run + Memorystore Redis savings starting to land.

---

## Phase G — WSS retirement (Phase 7 in the existing docs)

**Goal:** delete WSS infrastructure when telemetry justifies it.

Follow the gates in `docs/HERMES_IROH_RETIREMENT.md` exactly. Specifically:
- ≥99.5% iroh success for 14 consecutive days
- 0 WSS fallbacks for 14 consecutive days
- ≥75% iroh-direct (no hosted-relay assist)
- Hosted relay budget ≤100% of plan

When all gates are green, run the decommissioning sequence in that doc (Cloud Run service deletion, Memorystore Redis tear-down, billing alert cleanup). Verify the rollback playbook works before pulling the trigger.

**Gate G:** WSS infrastructure deleted, Cloud Run billing line item gone from the GCP bill, code removed in a follow-up "chore(hermes-relay): retire WSS" commit, `docs/HERMES_IROH_RETIREMENT.md` updated with the actual cutover date and final cost delta.

---

## Hard rules

- Never push to `main` directly.
- Never deploy to production Firebase without dry-run output approved by the user.
- Never run `cutover-n0-hosted-relay.sh provision` without explicit "yes, spend the $200/mo" from the user.
- Never roll out beyond the current Remote Config percentage without showing the user the telemetry that justifies the next step.
- If you find a P0 bug at any phase, stop the rollout, roll back the Remote Config percentage to zero if applicable, fix the bug, run the previous gate again from scratch.
- If you find the audit telemetry is lying or missing data, fix the telemetry before trusting the gates. Bad telemetry is worse than no telemetry.

---

## Output expectations

For each phase, produce:
1. A commit (or PR if it touches multiple phases) that closes that phase's coding work.
2. A short status note in `docs/runbooks/iroh-rollout-status.md` with: date, phase, gate status, anything the user needs to know.
3. A clear next-action statement at the top of every message back to the user: "Phase X gate is green, ready to start Phase X+1. Need your approval for [specific action]."

Start by reading `docs/HERMES_IROH_TRANSPORT.md`, `docs/HERMES_IROH_RETIREMENT.md`, and commit `072a96070` end to end. Then begin Phase A.
