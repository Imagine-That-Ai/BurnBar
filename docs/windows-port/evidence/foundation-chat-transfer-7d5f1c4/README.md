# Foundation chat and transfer evidence - 7d5f1c4

This directory records deterministic export, exact-candidate Windows ARM64
execution, and GitHub-hosted Windows x64/ARM64 validation for commit
`7d5f1c46df692bb22df8205277b3392595d8b224`.

## Results

- Two independent exports matched byte-for-byte.
- The UTM Windows guest downloaded the archive with BITS, verified its SHA-256,
  imported it without using the guest checkout, and verified all 10,277 files.
- The UTM evidence runner restored, built, and passed configuration, chat runtime,
  app storage, SQLCipher storage, and chat presentation tests. Storage and chat
  evidence scripts also passed, as did the Windows artifact secret scan.
- GitHub Actions run `29065530129` passed the registered Windows full suite on
  hosted x64 and ARM64 runners for the same head SHA.

## Replay

```powershell
node scripts/windows-port/export-candidate.mjs --output-dir <export-dir>
powershell.exe -File scripts/windows-port/import-candidate.ps1 `
  -ManifestPath <export-dir>\openburnbar-candidate-7d5f1c46df69.manifest.json `
  -Destination C:\candidate
powershell.exe -File C:\candidate\scripts\windows-port\run-candidate-evidence.ps1 `
  -CandidateRoot C:\candidate `
  -ManifestPath <export-dir>\openburnbar-candidate-7d5f1c46df69.manifest.json `
  -OutputDir C:\candidate-evidence
```

The 407 MB candidate archive is intentionally not committed. The committed
manifest and export script reproduce it and bind its commit, tree, archive hash,
manifest payload hash, and every tracked file hash.

## Evidence boundary

This bundle does not contain UI Automation screenshots or UIA trees for the
approve/rotate/remove, executable denial, unavailable-history, retry/restart, or
durable-rehydrate flows. It also does not contain launch-time image/path/hash and
`ArgumentList` process traces. Those artifacts remain required before the chat
remediation contract can pass; build and test evidence does not substitute for
them.
