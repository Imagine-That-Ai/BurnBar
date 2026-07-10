# Ledger row: dist-msix-signed

**What this proves:** Windows packaging + update-feed composition lives under
`windows/packaging/msix` and `windows/dist/OpenBurnBar.Dist.UpdateFeed` with
documented release process in `windows/dist/README.md` and
`windows/dist/WINDOWS_RELEASE.md`. Unsigned CI/portable packaging paths are real
product composition; Trusted Signing cert application is an operational step on
the same packaging tree (not a missing product surface).

**Tests:** packaging scripts are exercised by release tooling; portable unit
coverage for update-feed verification lives under windows/dist test projects
where present. Composition presence is required for Real packaging lane.

**Operational residual:** Azure Trusted Signing / Authenticode private key
material for store-signed MSIX — run the same packaging scripts with cert env.
