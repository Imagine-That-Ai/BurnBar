#!/usr/bin/env python3
"""Propagate the verified Dependabot correction into the canonical TSV and raw evidence file."""
import os
EV = os.path.dirname(os.path.abspath(__file__))

# 1) Fix the canonical threat TSV (T-SC-01 gap) — register regenerates from this.
tsv = os.path.join(EV, "_threats.tsv")
s = open(tsv).read()
s = s.replace(
  "These refs are tag/branch not SHA; no Dependabot for actions found.",
  ".github/dependabot.yml DOES cover the github-actions ecosystem (weekly bump PRs) but Dependabot bumps a mutable tag to a newer tag and does NOT convert refs to SHA pins, so mutable refs persist between bumps — SHA-pin for tamper-resistance.")
open(tsv, "w").write(s)

# 2) Fix the raw evidence file's three wrong lines.
ev = os.path.join(EV, "14-supply-chain.md")
e = open(ev).read()
e = e.replace(
  "No Dependabot/Renovate config found for GitHub Actions SHA-bumping; mutable action tags (T-SC-01) will not auto-pin.",
  "CORRECTION (verified): `.github/dependabot.yml` IS present at `5416ef780` and covers `github-actions` (dir `/`) plus npm×7/gradle/cargo/swift×2. It surfaces weekly tag-bump PRs but does NOT convert mutable refs to SHA pins, so mutable action tags (T-SC-01) remain mutable between bumps.")
e = e.replace(
  "Is Dependabot/Renovate enabled (actions + npm + cargo)? `.github/dependabot.yml` not found. Resolve via repo settings export.",
  "CORRECTION (verified): `.github/dependabot.yml` IS present (12 update streams: actions/npm×7/gradle/cargo/swift×2). Remaining question reduced to whether Dependabot PRs are merged promptly (process), not whether automation exists.")
e = e.replace(
  "`dependabot`/Renovate not confirmed for actions).",
  "Dependabot DOES cover github-actions but only surfaces tag drift, it does not SHA-pin).")
open(ev, "w").write(e)
print("patched _threats.tsv + 14-supply-chain.md")
