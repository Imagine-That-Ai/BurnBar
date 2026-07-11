# Ledger row: dist-msix-signed

**What this proves:** Windows packaging + update-feed composition lives under
`windows/packaging/msix` and `windows/dist/OpenBurnBar.Dist.UpdateFeed` with the
release process documented in `windows/dist/README.md` and
`windows/dist/WINDOWS_RELEASE.md`. The release workflow composes x64 and ARM64
portable ZIP and MSIX artifacts, applies Azure Artifact Signing when its
credentials are configured, verifies Authenticode signatures, finalizes
checksums after signing, signs the independent update feed, and emits supply
chain evidence.

**Tests:** release preflight fixtures, distribution and updater tests, packaging
script verification, version consistency, workflow lint, and hosted unsigned
rehearsals cover the fail-closed composition boundary.

**Operational residual:** a fresh exact-mainline signed release run must bind
the hosted artifacts and evidence to this candidate. Clean
install/update/rollback on physical x64 and ARM64 devices plus
Store/winget/Chocolatey publication remain separate certification gates.
