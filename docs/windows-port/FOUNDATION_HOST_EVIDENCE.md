# Windows foundation host evidence

The foundation host harness proves the Windows security, encrypted-storage,
chat-process, durable-chat, and diagnostic-redaction foundation against one
exact exported Git candidate. It does not certify whole-product parity.

## Run

Run the parent script from an elevated Windows process with an interactive user
signed in to the console. The parent may run in session 0; it launches the UIA
collector into the active console session with `WTSQueryUserToken` and
`CreateProcessAsUser`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\windows-port\run-foundation-host-evidence.ps1 `
  -RepoRoot C:\openburnbar-candidate `
  -ManifestPath C:\candidate\openburnbar-candidate-<sha>.manifest.json `
  -ExpectedCandidate <full-commit-sha> `
  -VmUuid <utm-vm-uuid> `
  -Platform ARM64 `
  -OutputDir C:\Users\Public\openburnbar-foundation-evidence
```

The runner verifies the candidate tree before executing tests. It then runs the
focused storage/chat evidence, the production-policy process harness, and the
interactive WinUI UIA collector. UI scenarios fail when the app window or an
expected automation control is absent. Process scenarios fail on shell launch,
forbidden child environment variables, output-limit failures that are not
contained, or surviving child processes.

The VM UUID, machine name, Windows identity, and interactive actor identity are
stored only as SHA-256 hashes. Process-table paths replace the active user
profile directory with `%USERPROFILE%`.

## Validate

Pull the complete output directory without editing it, then run:

```bash
node scripts/validate-windows-foundation-host-evidence.mjs \
  docs/windows-port/evidence/<bundle>/foundation-host-evidence-manifest.json \
  --expected-candidate <full-commit-sha>
```

The validator recomputes artifact sizes and SHA-256 digests and requires every
scenario, a non-session-0 UI actor, zero failed steps, zero surviving process
IDs, zero secret findings, and exact candidate identity. Its intentional
failure tests are:

```bash
node scripts/test-windows-foundation-host-evidence.mjs
```

Run the same committed candidate on hosted Windows x64 and the UTM Windows 11
ARM64 guest. Keep the two host identities and manifests separate. A green run
on one architecture does not substitute for the other.

## Data handling

The harness injects synthetic canaries, records environment variable names and
value hashes instead of values, redacts process samples, and scans the complete
output tree before emitting a passing manifest. Do not add real credentials to
the guest environment or commit raw artifacts that contain usernames, device
identifiers, tokens, addresses, or unredacted user content.
