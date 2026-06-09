# On-host agent/gateway runtime provenance (security remediation C-5)

## The gap

OpenBurnBar runs a Python agent/gateway runtime **on the user's Mac**
(`gateway/`, `plugins/`, `tools/`, `hermes_cli/`, `tui_gateway/`, `agent/`). It is
the most security-sensitive host-side component: it fronts provider API keys,
enforces the Cloudflare-tunnel auth, and is the host-side counterpart that must
authorize remote agent missions and verify the authenticated relay envelope.

In this repository that runtime ships as **compiled `.pyc` bytecode with the
`.py` source gitignored**. Consequences:

- A reviewer cannot read the code that enforces the host-side security checks.
- The AGPL corresponding-source archive (`scripts/create-corresponding-source.sh`)
  does **not** contain it.
- A tampered build cannot be detected from this repo.

For a trust-first product, the one component an auditor most needs to read is the
one they couldn't.

## The fix: a pinned, hashed, verifiable provenance pin

`third_party/hermes-agent/manifest.json` pins the runtime to an exact, auditable
source:

- `forkRepository` / `forkBranch` / `pinnedCommit` — the precise
  `NousResearch/hermes-agent` fork commit the bytecode is built from.
- `vendoredSourceTreeSha256` — a deterministic hash over every `.py` file in the
  vendored subtrees at that commit (definition below).

`scripts/ci/verify-vendored-agent-source.sh` recomputes that hash from a checkout
of the pinned fork and fails if it drifts — so the shipped runtime is provably
the reviewed source.

```
# hash definition (also implemented in the verifier):
#   for each *.py under {gateway,plugins,tools,hermes_cli,tui_gateway,agent} at pinnedCommit, sorted:
#       "<path> <sha256(blob)>\n"
#   vendoredSourceTreeSha256 = sha256(concatenation)
HERMES_AGENT_SRC=/path/to/hermes-agent scripts/ci/verify-vendored-agent-source.sh
```

## Operational steps (before beta)

1. **Merge the C-4 hardening.** The agent command-guard hardening (secret-read /
   exfil gating, fail-closed tirith, smart-mode escalation — branch
   `security/agent-sandbox-hardening`) is **not** in the currently-pinned commit
   `cde04bb9a`. Merge it into `ajnunezg/burnbar-gateway-e2ee`, re-vendor the
   bytecode, then update `pinnedCommit` + `vendoredSourceTreeSha256` and clear
   `pendingHardening.blocking`. The manifest flags this as blocking and the
   verifier warns until it is done.
2. **Wire the verifier into CI.** Add a checkout of the pinned fork to the
   release / corresponding-source job and run
   `scripts/ci/verify-vendored-agent-source.sh` (blocking). It is intentionally
   not wired in by default because the release runner does not yet clone the
   fork; do this as part of the fork's CI integration.
3. **Bundle the source in corresponding-source.** Extend
   `scripts/create-corresponding-source.sh` to include the pinned agent source
   tree so the AGPL/MIT corresponding-source archive is complete and the runtime
   is reproducible from source.

## Why pin instead of vendor inline

The runtime is a fork of the MIT-licensed upstream `NousResearch/hermes-agent`;
its source already lives in version control on that fork. Pinning + hashing
(mirroring `third_party/libsignal/manifest.json`) keeps the OpenBurnBar tree from
duplicating a large upstream while still giving auditors an exact, verifiable
source reference and a CI tripwire against tampering.
