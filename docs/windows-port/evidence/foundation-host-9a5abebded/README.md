# Windows foundation host evidence - 9a5abebded

Ledger rows: `nav-dashboard`, `nav-chat`, `nav-settings`, `shell-flyout`, and
`storage-sqlcipher-byte-compat`.

## What this proves

This receipt binds the Windows foundation evidence run to exact candidate
`9a5abebded057f59729fff1bd731e94d97fd6c27` and tree
`ecdc551805003ebf55b7ee7b1ff2009942475005`.

- The imported archive SHA-256 was
  `0dc01f1b6fbd3436e98060541a47b890191b90df3028d4d3a59ea33c016647b0`.
- Import and independent pre-run verification each checked `10,372 / 10,372`
  files with zero mismatches.
- All four runner stages exited `0`; all `53 / 53` required scenarios were
  captured with zero missing scenarios.
- All `14 / 14` interactive WinUI scenarios were captured in signed-in desktop
  session `1`, never session `0`.
- Fail-closed checks reported zero missing rows, failed commands, and secret
  findings. The stale-candidate and session-0 checks were both false.
- The host was a Windows 11 Pro ARM64 UTM guest. VM, computer, service actor,
  and interactive actor identities are retained only as SHA-256 hashes.

The run started at `2026-07-10T18:15:55.8452715Z` and completed at
`2026-07-10T18:25:40.7981636Z`. The public receipt contains 186 files and
5,851,299 bytes. Its post-redaction manifest SHA-256 is
`3f009a83d3d3ed865289f184e44563c6b448ec540b8e96cd6e8d8082c08587e6`.
`public-redaction-summary.json` binds that receipt to the raw transport archive
SHA-256 `cfb84e9c9e0e967c4ab6a1b882ec2d1ec6f9f3f46004afe902766f4b3d5bd015`
and raw manifest SHA-256
`406af0e7fd61823a977d1ace6f116cdbc2ffee2ee650170af99842b2148dcf6e`.

## Review entry points

- `candidate-import-verification.json` and `candidate-tree-verification.json`
  bind the archive to the imported source tree.
- `foundation-host-evidence-manifest.json` is the complete scenario and
  artifact index.
- `interactive-uia/interactive-result.json` records the real desktop actor and
  per-route UIA results.
- `process-traces/process-evidence.json` records direct-process containment,
  cancellation, timeout, output bounds, environment scrubbing, and denial
  behavior.
- `artifact-secret-scan.json` is the final synthetic-canary and structured
  secret scan.
- `public-redaction-summary.json` records the deterministic public-identity
  redaction and the raw-to-public hash chain.

Replay the independent validator with:

```bash
node scripts/validate-windows-foundation-host-evidence.mjs \
  docs/windows-port/evidence/foundation-host-9a5abebded/foundation-host-evidence-manifest.json \
  --expected-candidate 9a5abebded057f59729fff1bd731e94d97fd6c27
```

This evidence certifies the foundation scope on the named ARM64 guest. It does
not certify signed distribution, hosted or physical x64 hardware, production
cloud accounts, accessibility, performance, Computer Use, or Mercury.
