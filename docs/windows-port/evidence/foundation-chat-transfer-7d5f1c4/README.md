# Foundation Chat Transfer Evidence - 7d5f1c4

This directory contains evidence for candidate commit `7d5f1c46df692bb22df8205277b3392595d8b224` on branch `codex/windows-macos-parity-audit-implementation`.

## Candidate

- Commit: `7d5f1c46df692bb22df8205277b3392595d8b224`
- Tree: `7f6c988849675f4c4b68619c685ba8311fdf43b3`
- Export archive SHA-256: `65b2a52c700376336acae105c3632af8afb9bea1956092299eaf445e1d41f703`
- Manifest SHA-256: `35cd73407d6949ec606e3f7bfc3e0cc617c4ebd9bc5b1c0de0c24793677a933b`
- Manifest payload SHA-256: `d9936ad651ba42c043fbcb5f3357f8f4233cdf709f078f1f71c6ccfd169f956e`
- File count: 10,277

## Replay

Regenerate the deterministic candidate export:

```bash
node scripts/windows-port/export-candidate.mjs --output-dir /tmp/openburnbar-candidate-7d5f1c4
```

On Windows, import and verify the archive:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\windows-port\import-candidate.ps1 `
  -ArchivePath C:\path\openburnbar-candidate-7d5f1c46df69.tar.gz `
  -ManifestPath C:\path\openburnbar-candidate-7d5f1c46df69.manifest.json `
  -DestinationRoot C:\candidate7d5f1c4_run `
  -VerificationOutputPath C:\path\candidate-import-verification.json
```

Run the candidate evidence script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\candidate7d5f1c4_run\scripts\windows-port\run-candidate-evidence.ps1 `
  -RepoRoot C:\candidate7d5f1c4_run `
  -ManifestPath C:\path\openburnbar-candidate-7d5f1c46df69.manifest.json `
  -OutputDir C:\path\arm64-evidence-current
```

## Contents

- `candidate-export/`: deterministic export manifest for the candidate.
- `arm64-utm/`: exact-candidate transfer, import, build, focused test, storage evidence, chat evidence, protected-inventory metadata, and artifact secret scan from the existing UTM Windows ARM64 guest.
- `github-windows-full-suite/`: GitHub-hosted Windows x64/ARM64 full-suite run artifacts when available.
- `provenance-summary.json`: compact summary of candidate provenance, transfer/import hashes, host identity, validation steps, and known gaps.

## Boundary

The committed evidence proves deterministic export/import, ARM64 UTM build/test/storage/chat evidence, protected-inventory metadata, and hosted x64/ARM64 build/test once the GitHub run completes. It does not close the UIA/process-trace portion of the contracts: screenshots, UIA trees, approve/rotate/remove executable flows, denial flows, and image/path/ArgumentList traces still require a real Windows UIA runner.
