# ADR 011 — Toolchain pins: one pin per language, in-repo

- **Status:** Accepted (2026-09-02, Wave 0 workstream W0-7)
- **Supersedes:** the diligence P2-8 float note recorded in `.github/actions/openburnbar-test-matrix/action.yml` ("no DEVELOPER_DIR pin anywhere… A hard path pin breaks on every image refresh").

## Context

Builds depended on whatever the runner image happened to ship: Xcode drifted with image refreshes, Node varied per workflow (`20`/`22`/`24`), Rust `toolchain: stable` floats moved under shipping crates, and .NET had no floor file. The #2195-class failure mode: an image migration changes a compiler and every lane re-discovers it in parallel, or worse, silently builds different binaries.

## Decision

| Language | Pin file (in-repo, single source) | Consumed by |
|---|---|---|
| Node | `.nvmrc` | every workflow's `node-version-file: .nvmrc` |
| Rust | `crates/*/rust-toolchain.toml` (deliberately **two-channel**: `burnbar-remote` 1.94.0, the rest 1.96.0; `rust-sast.yml`'s matrix maps each crate to its own channel) | every workflow `toolchain:` literal / `rustup run` — enforced equal to the crate's own channel by `scripts/ci/check-toolchain-pins.mjs` |
| Xcode | `.xcode-version` (a **major/range**, e.g. `26`) | the `openburnbar-test-matrix` drift tripwire (reads the file; a hard `DEVELOPER_DIR` path pin stays forbidden — it breaks on image refresh) |
| .NET | `global.json` (`10.0` floor, `rollForward: latestFeature` — 54 `.csproj` files still target `net8.0`) | every `dotnet` lane |

**Enforcement:** `scripts/ci/check-toolchain-pins.mjs` (in Fast Feedback via the lint suite's test list and runnable anywhere). Every deviation lives in `governance/toolchain-pin-exceptions.json` — `{path, line, pin, reason, owner, expiresOn}` — which the checker **reads, prints in its normal output** (an exempted gate must never look like a clean one), and **fails closed on** when an entry is expired or its path/line no longer matches. The checker itself contains **no path literals** for exempted files.

**Automation posture:** no Dependabot/Renovate bumping (they cannot read these files; Renovate has no Xcode manager). Instead a read-only `toolchain-freshness` report (`.github/workflows/toolchain-freshness.yml`) publishes observed-vs-pinned versions as an artifact — no PR generation.

## Consequences

- An image migration fails **fast and named** (tripwire) instead of mid-build.
- Upgrading a channel is a one-file diff (`rust-toolchain.toml` per crate; `.nvmrc`; `.xcode-version`; `global.json`) reviewed by the same gate that previously couldn't see drift at all.
- `burnbar-remote` stays on 1.94.0: aligning it to 1.96.0 changes a shipping engine's compiler and is out of scope.
- The two Node-24 deploy-lane sites are time-boxed exceptions (expire 2026-12-01, owner Alberto): convert them when the deploy lane observably runs its pinned Node (human queue items 11–14).
